import Foundation

/// Reddit posts: videos (with sound), galleries, images and GIFs.
/// Reddit serves every post as JSON at `/comments/ID.json`. Videos come as a DASH
/// manifest with separate video and audio files, which Keepsake merges.
/// With a saved Reddit login, NSFW posts and private communities you're in work too.
enum RedditExtractor {
    static func media(from url: URL) async throws -> MediaBundle {
        let postURL = try await resolve(url)
        if let direct = directMedia(postURL) { return direct }
        guard let id = postID(in: postURL) else {
            throw KeepsakeError.server("That Reddit link doesn't point to a post.")
        }
        let post = try await fetchPost(id: id)
        // Crossposts keep their media on the original post.
        let media = (post["crosspost_parent_list"] as? [[String: Any]])?.first ?? post

        let author = post["author"] as? String
        let subreddit = post["subreddit"] as? String
        let title = (post["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        var caption = title
        if let sub = subreddit { caption = ["r/\(sub)", title].compactMap { $0 }.joined(separator: " · ") }
        let created = (post["created_utc"] as? NSNumber)?.doubleValue ?? 0
        let permalink = (post["permalink"] as? String).flatMap { URL(string: "https://www.reddit.com" + $0) } ?? postURL

        let items = try await items(in: media)
        if items.isEmpty { throw KeepsakeError.noMedia }
        return MediaBundle(platform: .reddit, title: author.map { "u/\($0)" } ?? "Reddit", caption: caption,
                           sourceURL: permalink, items: items, key: "reddit:\(id)",
                           date: created > 0 ? Date(timeIntervalSince1970: created) : nil)
    }

    // MARK: - Links

    /// Share links (reddit.com/r/x/s/CODE, redd.it/ID, v.redd.it/ID) redirect to the post.
    private static func resolve(_ url: URL) async throws -> URL {
        let host = url.host?.lowercased() ?? ""
        let parts = url.pathComponents
        let needsRedirect = host == "redd.it" || host == "v.redd.it" || parts.contains("s")
        guard needsRedirect, postID(in: url) == nil else { return url }
        var request = HTTP.pageRequest(url)
        request.httpMethod = "GET"
        let (_, response) = try await session.data(for: request)
        return response.url ?? url
    }

    static func postID(in url: URL) -> String? {
        let parts = url.pathComponents.filter { $0 != "/" }
        for marker in ["comments", "gallery"] {
            if let index = parts.firstIndex(of: marker), index + 1 < parts.count { return parts[index + 1] }
        }
        if url.host?.lowercased() == "redd.it", let first = parts.first, MediaLink.isShortcode(first) { return first }
        return nil
    }

    /// i.redd.it/abc.jpg links are the file itself.
    private static func directMedia(_ url: URL) -> MediaBundle? {
        guard url.host?.lowercased() == "i.redd.it" else { return nil }
        let ext = url.pathExtension.lowercased()
        let isVideo = ext == "mp4"
        let source = MediaSource(url: url, width: 0, height: 0)
        let item = MediaItem(kind: isVideo ? .video : .photo, thumbnailURL: url, standard: source, best: nil)
        return MediaBundle(platform: .reddit, title: "Reddit", caption: nil, sourceURL: url, items: [item],
                           key: "reddit:file:\(url.lastPathComponent)")
    }

    // MARK: - Post JSON

    /// Uses the saved Reddit login (if any) from the shared cookie store.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = AppGroup.cookieStorage
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    private static func fetchPost(id: String) async throws -> [String: Any] {
        var lastError: Error = KeepsakeError.notFound
        for host in ["www.reddit.com", "old.reddit.com"] {
            guard let url = URL(string: "https://\(host)/comments/\(id)/.json?raw_json=1&limit=1") else { continue }
            var request = URLRequest(url: url)
            request.setValue(HTTP.desktopUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                switch status {
                case 200:
                    if let listing = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                       let post = ((listing.first?["data"] as? [String: Any])?["children"] as? [[String: Any]])?
                        .first?["data"] as? [String: Any] {
                        return post
                    }
                    lastError = KeepsakeError.notFound
                case 401, 403:
                    lastError = Accounts.isLoggedIn(.reddit) ? KeepsakeError.notFound : KeepsakeError.loginRequiredFor(.reddit)
                case 404:
                    throw KeepsakeError.notFound
                case 429:
                    lastError = KeepsakeError.rateLimited
                default:
                    lastError = KeepsakeError.server("Reddit didn't respond properly (error \(status)). Try again in a moment.")
                }
            } catch let error as KeepsakeError {
                throw error
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    // MARK: - Media

    private static func items(in post: [String: Any]) async throws -> [MediaItem] {
        // Gallery: several photos (and sometimes GIFs), in the order the poster chose.
        if let metadata = post["media_metadata"] as? [String: [String: Any]], !metadata.isEmpty {
            let order = ((post["gallery_data"] as? [String: Any])?["items"] as? [[String: Any]])?
                .compactMap { $0["media_id"] as? String } ?? Array(metadata.keys)
            let galleryItems = order.compactMap { metadata[$0] }.compactMap(galleryItem)
            if !galleryItems.isEmpty { return galleryItems }
        }

        // Reddit-hosted video (also used for GIFs uploaded as video).
        let media = (post["secure_media"] as? [String: Any]) ?? (post["media"] as? [String: Any])
        let preview = post["preview"] as? [String: Any]
        if let video = (media?["reddit_video"] as? [String: Any]) ?? (preview?["reddit_video_preview"] as? [String: Any]) {
            let thumb = previewImage(preview)?.url ?? HTTP.url(post["thumbnail"])
            if let item = await videoItem(video, thumbnail: thumb) { return [item] }
        }

        // Single image or GIF.
        let link = HTTP.url(post["url_overridden_by_dest"]) ?? HTTP.url(post["url"])
        if let image = previewImage(preview) {
            if let mp4 = gifVideo(preview) {
                return [MediaItem(kind: .video, thumbnailURL: image.url, standard: mp4, best: nil)]
            }
            let host = link?.host?.lowercased() ?? ""
            let original = (host == "i.redd.it" || ["jpg", "jpeg", "png", "webp"].contains(link?.pathExtension.lowercased() ?? ""))
                ? link.map { MediaSource(url: $0, width: image.width, height: image.height) } : nil
            let standard = original ?? image
            return [MediaItem(kind: .photo, thumbnailURL: image.url, standard: standard, best: nil)]
        }
        if let link, ["jpg", "jpeg", "png", "webp"].contains(link.pathExtension.lowercased()) {
            return [MediaItem(kind: .photo, thumbnailURL: link, standard: MediaSource(url: link, width: 0, height: 0), best: nil)]
        }
        return []
    }

    private static func galleryItem(_ entry: [String: Any]) -> MediaItem? {
        guard (entry["status"] as? String ?? "valid") == "valid", let s = entry["s"] as? [String: Any] else { return nil }
        let width = HTTP.int(s["x"]), height = HTTP.int(s["y"])
        if let mp4 = HTTP.url(s["mp4"]) {
            let thumb = HTTP.url(s["gif"]) ?? mp4
            return MediaItem(kind: .video, thumbnailURL: thumb, standard: MediaSource(url: mp4, width: width, height: height), best: nil)
        }
        guard let preview = HTTP.url(s["u"]) ?? HTTP.url(s["gif"]) else { return nil }
        // The original upload lives on i.redd.it under the same ID; the preview is the fallback.
        var file = preview
        if let id = entry["id"] as? String, let mime = entry["m"] as? String,
           let ext = mime.split(separator: "/").last, let original = URL(string: "https://i.redd.it/\(id).\(ext)") {
            file = original
        }
        return MediaItem(kind: .photo, thumbnailURL: preview, standard: MediaSource(url: file, width: width, height: height), best: nil)
    }

    /// The fallback MP4 has no sound, so the standard version pairs it with the audio track
    /// from the DASH manifest; the best version is the highest-resolution DASH stream.
    private static func videoItem(_ video: [String: Any], thumbnail: URL?) async -> MediaItem? {
        guard let fallback = HTTP.url(video["fallback_url"]) else { return nil }
        let width = HTTP.int(video["width"]), height = HTTP.int(video["height"])
        let hasAudio = (video["has_audio"] as? Bool ?? true) && !(video["is_gif"] as? Bool ?? false)

        var reps: [DashRepresentation] = []
        if let dashURL = HTTP.url(video["dash_url"]),
           let (data, _) = try? await HTTP.anonymous.data(from: dashURL),
           let xml = String(data: data, encoding: .utf8) {
            reps = DASH.representations(fromManifest: xml, relativeTo: dashURL)
        }
        let audioURL: URL? = hasAudio ? reps.filter { $0.isAudio && $0.baseURL != nil }.max { $0.bandwidth < $1.bandwidth }?.baseURL : nil

        let standard = MediaSource(url: fallback, audioURL: audioURL, width: width, height: height, codec: "avc1")
        let best = DASH.bestSource(from: reps).map { source -> MediaSource in
            var source = source
            if !hasAudio { source.audioURL = nil }
            return source
        }
        let audio = audioURL.map { MediaSource(url: $0, width: 0, height: 0, codec: "mp4a") }
        return MediaItem(kind: .video, thumbnailURL: thumbnail ?? fallback, standard: standard,
                         best: best.flatMap { $0.pixelCount > standard.pixelCount ? $0 : nil }, audio: audio)
    }

    private static func previewImage(_ preview: [String: Any]?) -> MediaSource? {
        guard let image = (preview?["images"] as? [[String: Any]])?.first,
              let source = image["source"] as? [String: Any], let url = HTTP.url(source["url"]) else { return nil }
        return MediaSource(url: url, width: HTTP.int(source["width"]), height: HTTP.int(source["height"]))
    }

    /// Reddit converts GIFs to MP4; prefer that over the (much larger) GIF.
    private static func gifVideo(_ preview: [String: Any]?) -> MediaSource? {
        guard let image = (preview?["images"] as? [[String: Any]])?.first,
              let variants = image["variants"] as? [String: Any],
              let mp4 = (variants["mp4"] as? [String: Any])?["source"] as? [String: Any],
              let url = HTTP.url(mp4["url"]) else { return nil }
        return MediaSource(url: url, width: HTTP.int(mp4["width"]), height: HTTP.int(mp4["height"]))
    }
}
