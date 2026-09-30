import Foundation

enum IGError: LocalizedError {
    case badLink
    case loginRequired
    case checkpoint
    case notFound
    case rateLimited
    case noMedia
    case server(String)

    var errorDescription: String? {
        switch self {
        case .badLink:
            return "That doesn't look like an Instagram post, reel or story link."
        case .loginRequired:
            return "Instagram wants you to be logged in for this. Tap the person icon (top right) to log in."
        case .checkpoint:
            return "Instagram wants to confirm it's you. Open the login screen (person icon), finish the check there, then try again."
        case .notFound:
            return "Couldn't find it. The post may be deleted, the story may have expired (24 hours), or the account is private and you don't follow it."
        case .rateLimited:
            return "Instagram is limiting requests right now. Wait a few minutes and try again."
        case .noMedia:
            return "Found the link but no photos or videos in it."
        case .server(let message):
            return "Instagram returned an error: \(message)"
        }
    }
}

/// Talks to the same endpoints instagram.com's own web app uses.
final class InstagramClient {
    static let shared = InstagramClient()

    /// Instagram's public web app ID (sent by instagram.com itself on every API call).
    private let webAppID = "936619743392459"
    /// Query ID the web app uses to load a single post when logged out. Instagram rotates this
    /// every so often; logged-in fetches don't depend on it.
    private let postQueryDocID = "8845758582119845"

    /// Browser identity for API calls. It matches the desktop web app whose ID is sent below.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)
    }

    // MARK: - Login state

    private static let instagramURL = URL(string: "https://www.instagram.com/")!

    private func cookie(_ name: String) -> String? {
        HTTPCookieStorage.shared.cookies(for: Self.instagramURL)?
            .first { $0.name == name && !$0.value.isEmpty }?.value
    }

    var isLoggedIn: Bool { cookie("sessionid") != nil }

    // MARK: - Public entry point

    func fetch(_ link: InstagramLink) async throws -> FetchResult {
        switch link {
        case .post(let shortcode):
            return try await fetchPost(shortcode: shortcode)
        case .story(let username, let storyID):
            return try await fetchStories(username: username, storyID: storyID)
        case .highlight(let id, let itemID):
            return try await fetchHighlight(id: id, itemID: itemID)
        case .shareRedirect(let url):
            let resolved = try await resolveShareLink(url)
            if case .shareRedirect = resolved { throw IGError.badLink }
            return try await fetch(resolved)
        }
    }

    // MARK: - Posts & reels

    private func fetchPost(shortcode: String) async throws -> FetchResult {
        if isLoggedIn, let mediaID = InstagramLink.mediaID(fromShortcode: shortcode) {
            let json = try await getJSON("media/\(mediaID)/info/")
            guard let items = json["items"] as? [[String: Any]], let media = items.first else {
                throw IGError.notFound
            }
            return FetchResult(title: title(for: media, fallback: "Post"), items: try nonEmpty(Self.items(fromAPIMedia: media)))
        }
        return try await fetchPostLoggedOut(shortcode: shortcode)
    }

    /// Best-effort path for public posts without logging in.
    private func fetchPostLoggedOut(shortcode: String) async throws -> FetchResult {
        if cookie("csrftoken") == nil {
            // Visiting the home page hands out the csrftoken cookie the query needs.
            _ = try? await session.data(for: webRequest(Self.instagramURL))
        }
        let variables = "{\"shortcode\":\"\(shortcode)\",\"fetch_tagged_user_count\":null,\"hoisted_comment_id\":null,\"hoisted_reply_id\":null}"
        var components = URLComponents(string: "https://www.instagram.com/graphql/query/")!
        components.queryItems = [
            URLQueryItem(name: "doc_id", value: postQueryDocID),
            URLQueryItem(name: "variables", value: variables),
        ]
        let req = apiHeaders(URLRequest(url: components.url!))

        let json: [String: Any]
        do {
            json = try await sendJSON(req)
        } catch IGError.server, IGError.notFound {
            throw IGError.loginRequired
        }
        guard let data = json["data"] as? [String: Any],
              let media = (data["xdt_shortcode_media"] ?? data["shortcode_media"]) as? [String: Any] else {
            throw IGError.loginRequired
        }
        let owner = (media["owner"] as? [String: Any])?["username"] as? String
        return FetchResult(title: owner.map { "@\($0)" } ?? "Post", items: try nonEmpty(Self.items(fromGraphQLMedia: media)))
    }

    // MARK: - Stories & highlights

    private func fetchStories(username: String, storyID: String?) async throws -> FetchResult {
        guard isLoggedIn else { throw IGError.loginRequired }
        let profile = try await getJSON("users/web_profile_info/", query: [URLQueryItem(name: "username", value: username)])
        guard let user = (profile["data"] as? [String: Any])?["user"] as? [String: Any],
              let userID = Self.string(user["id"]) else {
            throw IGError.notFound
        }
        let items = try await reelItems(reelID: userID, onlyItem: storyID)
        let label = storyID == nil ? "@\(username) · stories" : "@\(username) · story"
        return FetchResult(title: label, items: items)
    }

    private func fetchHighlight(id: String, itemID: String?) async throws -> FetchResult {
        guard isLoggedIn else { throw IGError.loginRequired }
        let items = try await reelItems(reelID: "highlight:\(id)", onlyItem: itemID)
        return FetchResult(title: "Highlight", items: items)
    }

    private func reelItems(reelID: String, onlyItem: String?) async throws -> [MediaItem] {
        let json = try await getJSON("feed/reels_media/", query: [URLQueryItem(name: "reel_ids", value: reelID)])
        var reels: [[String: Any]] = json["reels_media"] as? [[String: Any]] ?? []
        if reels.isEmpty, let dict = json["reels"] as? [String: Any] {
            reels = dict.values.compactMap { $0 as? [String: Any] }
        }
        var stories = reels.flatMap { $0["items"] as? [[String: Any]] ?? [] }
        if stories.isEmpty { throw IGError.notFound }

        if let onlyItem {
            let match = stories.filter { story in
                Self.string(story["pk"]) == onlyItem
                    || (Self.string(story["id"])?.hasPrefix(onlyItem + "_") ?? false)
            }
            // If the specific story has expired, fall back to showing whatever is still up.
            if !match.isEmpty { stories = match }
        }
        return try nonEmpty(stories.flatMap { Self.items(fromAPIMedia: $0) })
    }

    // MARK: - Share links

    private func resolveShareLink(_ url: URL) async throws -> InstagramLink {
        let (_, response) = try await session.data(for: webRequest(url))
        guard let finalURL = response.url else { throw IGError.badLink }
        if let link = InstagramLink.parse(url: finalURL), link != .shareRedirect(finalURL) {
            return link
        }
        // Logged-out redirects can land on the login page with the real path in ?next=
        if let next = URLComponents(url: finalURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "next" })?.value,
           let nextURL = URL(string: next, relativeTo: Self.instagramURL)?.absoluteURL,
           let link = InstagramLink.parse(url: nextURL) {
            return link
        }
        throw IGError.badLink
    }

    // MARK: - Networking

    private func webRequest(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        return req
    }

    private func apiHeaders(_ request: URLRequest) -> URLRequest {
        var req = request
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        req.setValue(webAppID, forHTTPHeaderField: "X-IG-App-ID")
        req.setValue("129477", forHTTPHeaderField: "X-ASBD-ID")
        req.setValue("0", forHTTPHeaderField: "X-IG-WWW-Claim")
        req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        req.setValue("https://www.instagram.com/", forHTTPHeaderField: "Referer")
        req.setValue("https://www.instagram.com", forHTTPHeaderField: "Origin")
        if let csrf = cookie("csrftoken") {
            req.setValue(csrf, forHTTPHeaderField: "X-CSRFToken")
        }
        return req
    }

    private func getJSON(_ path: String, query: [URLQueryItem] = []) async throws -> [String: Any] {
        var components = URLComponents(string: "https://www.instagram.com/api/v1/" + path)!
        if !query.isEmpty { components.queryItems = query }
        return try await sendJSON(apiHeaders(URLRequest(url: components.url!)))
    }

    private func sendJSON(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let message = (json?["message"] as? String) ?? ""

        if message.contains("checkpoint") || message.contains("challenge") { throw IGError.checkpoint }
        if message.contains("login_required") || status == 401 { throw IGError.loginRequired }
        if status == 429 || message.lowercased().contains("wait a few minutes") { throw IGError.rateLimited }
        if status == 404 || message.contains("Media not found") { throw IGError.notFound }

        // An HTML page instead of JSON almost always means we were bounced to the login page.
        if json == nil {
            if response.url?.path.contains("/accounts/login") == true || status == 200 {
                throw IGError.loginRequired
            }
            throw IGError.server("HTTP \(status)")
        }
        if status == 403 { throw isLoggedIn ? IGError.notFound : IGError.loginRequired }
        guard (200..<300).contains(status), let json else {
            throw IGError.server(message.isEmpty ? "HTTP \(status)" : message)
        }
        return json
    }

    // MARK: - JSON → MediaItem

    /// Parses media from the /api/v1 endpoints (posts, reels, stories, highlights).
    static func items(fromAPIMedia media: [String: Any]) -> [MediaItem] {
        if let carousel = media["carousel_media"] as? [[String: Any]], !carousel.isEmpty {
            return carousel.flatMap { items(fromAPIMedia: $0) }
        }
        let images = ((media["image_versions2"] as? [String: Any])?["candidates"] as? [[String: Any]]) ?? []
        guard let image = best(images) else { return [] }

        if let videos = media["video_versions"] as? [[String: Any]], let video = best(videos) {
            return [MediaItem(kind: .video, url: video.url, thumbnailURL: image.url, width: video.width, height: video.height)]
        }
        return [MediaItem(kind: .photo, url: image.url, thumbnailURL: image.url, width: image.width, height: image.height)]
    }

    /// Parses media from the logged-out GraphQL post query.
    static func items(fromGraphQLMedia media: [String: Any]) -> [MediaItem] {
        if let edges = (media["edge_sidecar_to_children"] as? [String: Any])?["edges"] as? [[String: Any]], !edges.isEmpty {
            return edges.compactMap { $0["node"] as? [String: Any] }.flatMap { items(fromGraphQLMedia: $0) }
        }
        guard let display = (media["display_url"] as? String).flatMap(URL.init(string:)) else { return [] }
        let dims = media["dimensions"] as? [String: Any]
        let w = int(dims?["width"]), h = int(dims?["height"])
        if (media["is_video"] as? Bool) == true, let video = (media["video_url"] as? String).flatMap(URL.init(string:)) {
            return [MediaItem(kind: .video, url: video, thumbnailURL: display, width: w, height: h)]
        }
        return [MediaItem(kind: .photo, url: display, thumbnailURL: display, width: w, height: h)]
    }

    private static func best(_ candidates: [[String: Any]]) -> (url: URL, width: Int, height: Int)? {
        candidates
            .compactMap { c -> (url: URL, width: Int, height: Int)? in
                guard let s = c["url"] as? String, let url = URL(string: s) else { return nil }
                return (url, int(c["width"]), int(c["height"]))
            }
            .max { $0.width * $0.height < $1.width * $1.height }
    }

    private func title(for media: [String: Any], fallback: String) -> String {
        if let user = media["user"] as? [String: Any], let name = user["username"] as? String { return "@\(name)" }
        return fallback
    }

    private func nonEmpty(_ items: [MediaItem]) throws -> [MediaItem] {
        if items.isEmpty { throw IGError.noMedia }
        return items
    }

    private static func int(_ value: Any?) -> Int {
        if let n = value as? Int { return n }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String, let n = Int(s) { return n }
        return 0
    }

    static func string(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }
}
