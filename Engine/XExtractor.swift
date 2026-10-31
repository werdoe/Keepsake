import Foundation

/// X (Twitter) posts: photos at original size, videos and GIFs at the highest bitrate.
///
/// 1. X's embed service (the one that powers embedded posts on websites) returns public
///    posts as JSON without logging in.
/// 2. If that fails, or the post is age-restricted / from a protected account, the post page
///    is loaded in the hidden web view (with your saved X login, if any) and the post data
///    X's own web app loads is read from there.
enum XExtractor {
    static func media(from url: URL) async throws -> MediaBundle {
        guard let id = postID(in: url) else {
            throw KeepsakeError.server("That X link doesn't point to a post.")
        }
        if let bundle = try? await fromEmbed(id: id), !bundle.items.isEmpty {
            return bundle
        }
        return try await fromPage(id: id)
    }

    /// x.com/user/status/ID, twitter.com/i/status/ID, …/status/ID/photo/1
    static func postID(in url: URL) -> String? {
        let parts = url.pathComponents.filter { $0 != "/" }
        for (index, part) in parts.enumerated() where (part == "status" || part == "statuses") && index + 1 < parts.count {
            let candidate = parts[index + 1]
            if MediaLink.isDigits(candidate) { return candidate }
        }
        return nil
    }

    // MARK: - Embed JSON (logged out)

    private static func fromEmbed(id: String) async throws -> MediaBundle {
        var components = URLComponents(string: "https://cdn.syndication.twimg.com/tweet-result")!
        components.queryItems = [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "lang", value: "en"),
            URLQueryItem(name: "token", value: embedToken(for: id)),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(HTTP.desktopUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await HTTP.anonymous.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        if status == 404 { throw KeepsakeError.notFound }
        if status == 429 { throw KeepsakeError.rateLimited }
        guard status == 200, let tweet = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              tweet["__typename"] as? String != "TweetTombstone" else {
            throw KeepsakeError.notFound
        }

        var media = tweet["mediaDetails"] as? [[String: Any]] ?? []
        if media.isEmpty, let quoted = tweet["quoted_tweet"] as? [String: Any] {
            media = quoted["mediaDetails"] as? [[String: Any]] ?? []
        }
        let user = tweet["user"] as? [String: Any]
        return bundle(id: id, handle: user?["screen_name"] as? String, text: tweet["text"] as? String,
                      date: isoDate(tweet["created_at"] as? String), media: media)
    }

    /// The embed service wants a token derived from the post ID (same formula as X's embed script):
    /// (id / 1e15 × π) written in base 36, without zeros or the point.
    static func embedToken(for id: String) -> String {
        let value = (Double(id) ?? 0) / 1e15 * Double.pi
        return base36(value).replacingOccurrences(of: "0", with: "").replacingOccurrences(of: ".", with: "")
    }

    /// Base-36 text of a positive number, digit for digit as JavaScript's `toString(36)` writes it.
    private static func base36(_ value: Double) -> String {
        let chars = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        let radix = 36.0
        var integer = value.rounded(.down)
        var fraction = value - integer
        var delta = max(0.5 * (value.nextUp - value), Double.leastNonzeroMagnitude)
        var digits: [Int] = []
        if fraction >= delta {
            repeat {
                fraction *= radix
                delta *= radix
                let digit = Int(fraction)
                digits.append(digit)
                fraction -= Double(digit)
                if fraction > 0.5 || (fraction == 0.5 && digit & 1 == 1), fraction + delta > 1 {
                    // Round up, carrying into earlier digits.
                    while true {
                        guard let last = digits.popLast() else { integer += 1; break }
                        if last + 1 < 36 { digits.append(last + 1); break }
                    }
                    break
                }
            } while fraction >= delta
        }
        var integerText = ""
        repeat {
            let remainder = integer.truncatingRemainder(dividingBy: radix)
            integerText = String(chars[Int(remainder)]) + integerText
            integer = (integer - remainder) / radix
        } while integer > 0
        return digits.isEmpty ? integerText : integerText + "." + String(digits.map { chars[$0] })
    }

    // MARK: - Post page (logged in, or when the embed refuses)

    private static func fromPage(id: String) async throws -> MediaBundle {
        guard let url = URL(string: "https://x.com/i/status/\(id)") else { throw KeepsakeError.notFound }
        let result = try await WebCapture.capture(url, platform: .x, timeout: 25) { json in
            tweet(in: json, id: id) != nil
        }
        guard let tweet = tweet(in: result.json, id: id), let legacy = tweet["legacy"] as? [String: Any] else {
            throw Accounts.isLoggedIn(.x) ? KeepsakeError.notFound : KeepsakeError.loginRequiredFor(.x)
        }
        var media = (legacy["extended_entities"] as? [String: Any])?["media"] as? [[String: Any]] ?? []
        if media.isEmpty, let quoted = (tweet["quoted_status_result"] as? [String: Any])?["result"] as? [String: Any] {
            let inner = (quoted["tweet"] as? [String: Any]) ?? quoted
            media = ((inner["legacy"] as? [String: Any])?["extended_entities"] as? [String: Any])?["media"] as? [[String: Any]] ?? []
        }
        let user = ((tweet["core"] as? [String: Any])?["user_results"] as? [String: Any])?["result"] as? [String: Any]
        let handle = ((user?["core"] as? [String: Any])?["screen_name"] as? String)
            ?? ((user?["legacy"] as? [String: Any])?["screen_name"] as? String)
        let text = ((((tweet["note_tweet"] as? [String: Any])?["note_tweet_results"] as? [String: Any])?["result"]
                     as? [String: Any])?["text"] as? String) ?? legacy["full_text"] as? String
        return bundle(id: id, handle: handle, text: text, date: twitterDate(legacy["created_at"] as? String), media: media)
    }

    /// The post object (with `legacy`) whose `rest_id` is the post ID, anywhere in X's responses.
    private static func tweet(in json: [Any], id: String) -> [String: Any]? {
        for blob in json {
            if let found = HTTP.findDictionaries(in: blob, limit: 1, where: {
                ($0["rest_id"] as? String) == id && $0["legacy"] is [String: Any]
            }).first {
                return found
            }
        }
        return nil
    }

    // MARK: - Shared

    /// Both sources describe media the same way (X's API "media" objects).
    private static func bundle(id: String, handle: String?, text: String?, date: Date?, media: [[String: Any]]) -> MediaBundle {
        let items = media.compactMap(item)
        let caption = text.map(cleanText).flatMap { $0.isEmpty ? nil : $0 }
        let source = URL(string: "https://x.com/\(handle ?? "i")/status/\(id)")!
        return MediaBundle(platform: .x, title: handle.map { "@\($0)" } ?? "X", caption: caption,
                           sourceURL: source, items: items, key: "x:\(id)", date: date)
    }

    private static func item(_ media: [String: Any]) -> MediaItem? {
        guard let thumb = HTTP.url(media["media_url_https"]) else { return nil }
        let info = media["original_info"] as? [String: Any]
        let width = HTTP.int(info?["width"]), height = HTTP.int(info?["height"])
        switch media["type"] as? String {
        case "video", "animated_gif":
            let variants = ((media["video_info"] as? [String: Any])?["variants"] as? [[String: Any]] ?? [])
                .filter { ($0["content_type"] as? String) == "video/mp4" }
                .compactMap { variant -> (MediaSource, Int)? in
                    guard let url = HTTP.url(variant["url"]) else { return nil }
                    let size = dimensions(in: url) ?? (width, height)
                    return (MediaSource(url: url, width: size.0, height: size.1, codec: "avc1"), HTTP.int(variant["bitrate"]))
                }
                .sorted { ($0.0.pixelCount, $0.1) < ($1.0.pixelCount, $1.1) }
            guard let best = variants.last?.0 else { return nil }
            // Medium quality as the standard file when there's a choice; the top one as best.
            let standard = variants.count > 2 ? variants[variants.count - 2].0 : best
            return MediaItem(kind: .video, thumbnailURL: thumb, standard: standard,
                             best: best.pixelCount > standard.pixelCount ? best : nil)
        default:
            // name=orig gives the photo as uploaded instead of a resized copy.
            var components = URLComponents(url: thumb, resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "name", value: "orig")]
            let original = components?.url ?? thumb
            return MediaItem(kind: .photo, thumbnailURL: thumb,
                             standard: MediaSource(url: original, width: width, height: height), best: nil)
        }
    }

    /// Video URLs carry their size: …/vid/avc1/1280x720/file.mp4
    private static func dimensions(in url: URL) -> (Int, Int)? {
        for part in url.pathComponents {
            let numbers = part.split(separator: "x").compactMap { Int($0) }
            if numbers.count == 2, numbers[0] > 0, numbers[1] > 0 { return (numbers[0], numbers[1]) }
        }
        return nil
    }

    /// Drops the t.co link X appends for attached media.
    private static func cleanText(_ text: String) -> String {
        let trimmed = text.replacingOccurrences(of: #"\s*https://t\.co/\w+\s*$"#, with: "", options: .regularExpression)
        return HTTP.decodeHTMLEntities(trimmed).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isoDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    /// "Wed Oct 10 20:19:24 +0000 2018"
    private static func twitterDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM dd HH:mm:ss Z yyyy"
        return formatter.date(from: text)
    }
}
