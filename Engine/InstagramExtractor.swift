import Foundation

/// Fetches Instagram posts, reels, stories and highlights using the endpoints instagram.com uses.
enum InstagramExtractor {
    private static let webAppID = "936619743392459"
    /// Query the web app uses to load one post when logged out. Instagram rotates this now and then.
    private static let postQueryDocID = "8845758582119845"
    private static let home = URL(string: "https://www.instagram.com/")!

    static var isLoggedIn: Bool { cookie("sessionid") != nil }

    static func cookie(_ name: String) -> String? {
        AppGroup.cookieStorage.cookies(for: home)?.first { $0.name == name && !$0.value.isEmpty }?.value
    }

    // MARK: - Posts & reels

    static func post(shortcode: String, url: URL) async throws -> MediaBundle {
        let source = URL(string: "https://www.instagram.com/p/\(shortcode)/") ?? url
        if isLoggedIn, let mediaID = MediaLink.mediaID(fromShortcode: shortcode) {
            let json = try await api("media/\(mediaID)/info/")
            guard let media = (json["items"] as? [[String: Any]])?.first else { throw KeepsakeError.notFound }
            return try bundle(from: media, fallbackTitle: "Post", source: source)
        }
        // Logged out: try the page's embedded data first, then the web app's post query.
        if let media = try? await mediaFromPage(shortcode: shortcode) {
            return try bundle(from: media, fallbackTitle: "Post", source: source)
        }
        if let media = try? await mediaFromQuery(shortcode: shortcode) {
            let items = graphQLItems(media)
            if !items.isEmpty {
                let owner = (media["owner"] as? [String: Any])?["username"] as? String
                return MediaBundle(platform: .instagram, title: owner.map { "@\($0)" } ?? "Post",
                                   caption: nil, sourceURL: source, items: items)
            }
        }
        throw KeepsakeError.loginRequired
    }

    private static func mediaFromPage(shortcode: String) async throws -> [String: Any]? {
        let url = URL(string: "https://www.instagram.com/p/\(shortcode)/")!
        let (html, _) = try await HTTP.fetchPage(url)
        for json in HTTP.jsonScripts(in: html) {
            let matches = HTTP.findDictionaries(in: json, limit: 1) { dict in
                (dict["code"] as? String) == shortcode && (dict["image_versions2"] != nil || dict["carousel_media"] != nil)
            }
            if let media = matches.first { return media }
        }
        return nil
    }

    private static func mediaFromQuery(shortcode: String) async throws -> [String: Any]? {
        let variables = "{\"shortcode\":\"\(shortcode)\",\"fetch_tagged_user_count\":null,\"hoisted_comment_id\":null,\"hoisted_reply_id\":null}"
        var components = URLComponents(string: "https://www.instagram.com/graphql/query/")!
        components.queryItems = [
            URLQueryItem(name: "doc_id", value: postQueryDocID),
            URLQueryItem(name: "variables", value: variables),
        ]
        let json = try await send(apiRequest(components.url!))
        let data = json["data"] as? [String: Any]
        return (data?["xdt_shortcode_media"] ?? data?["shortcode_media"]) as? [String: Any]
    }

    /// Items from the older GraphQL post format (display_url / video_url / sidecar edges).
    private static func graphQLItems(_ media: [String: Any]) -> [MediaItem] {
        if let edges = (media["edge_sidecar_to_children"] as? [String: Any])?["edges"] as? [[String: Any]], !edges.isEmpty {
            return edges.compactMap { $0["node"] as? [String: Any] }.flatMap { graphQLItems($0) }
        }
        guard let display = HTTP.url(media["display_url"]) else { return [] }
        let dims = media["dimensions"] as? [String: Any]
        let w = HTTP.int(dims?["width"]), h = HTTP.int(dims?["height"])
        if (media["is_video"] as? Bool) == true, let video = HTTP.url(media["video_url"]) {
            return [MediaItem(kind: .video, thumbnailURL: display,
                              standard: MediaSource(url: video, width: w, height: h), best: nil)]
        }
        return [MediaItem(kind: .photo, thumbnailURL: display,
                          standard: MediaSource(url: display, width: w, height: h), best: nil)]
    }

    // MARK: - Stories & highlights

    static func stories(username: String, storyID: String?) async throws -> MediaBundle {
        guard isLoggedIn else { throw KeepsakeError.loginRequired }
        let profile = try await api("users/web_profile_info/", query: [URLQueryItem(name: "username", value: username)])
        guard let user = (profile["data"] as? [String: Any])?["user"] as? [String: Any],
              let userID = HTTP.string(user["id"]) else { throw KeepsakeError.notFound }
        let items = try await reelItems(reelID: userID, onlyItem: storyID)
        return MediaBundle(platform: .instagram, title: "@\(username)",
                           caption: storyID == nil ? "Stories" : "Story",
                           sourceURL: URL(string: "https://www.instagram.com/stories/\(username)/")!, items: items)
    }

    static func highlight(id: String, itemID: String?) async throws -> MediaBundle {
        guard isLoggedIn else { throw KeepsakeError.loginRequired }
        let items = try await reelItems(reelID: "highlight:\(id)", onlyItem: itemID)
        return MediaBundle(platform: .instagram, title: "Highlight", caption: nil,
                           sourceURL: URL(string: "https://www.instagram.com/stories/highlights/\(id)/")!, items: items)
    }

    private static func reelItems(reelID: String, onlyItem: String?) async throws -> [MediaItem] {
        let json = try await api("feed/reels_media/", query: [URLQueryItem(name: "reel_ids", value: reelID)])
        var reels = json["reels_media"] as? [[String: Any]] ?? []
        if reels.isEmpty, let dict = json["reels"] as? [String: Any] {
            reels = dict.values.compactMap { $0 as? [String: Any] }
        }
        var stories = reels.flatMap { $0["items"] as? [[String: Any]] ?? [] }
        if stories.isEmpty { throw KeepsakeError.notFound }
        if let onlyItem {
            let match = stories.filter {
                HTTP.string($0["pk"]) == onlyItem || (HTTP.string($0["id"])?.hasPrefix(onlyItem + "_") ?? false)
            }
            if !match.isEmpty { stories = match }
        }
        let items = stories.flatMap { MetaMediaParser.items(from: $0) }
        if items.isEmpty { throw KeepsakeError.noMedia }
        return items
    }

    // MARK: - Share links

    static func resolve(_ url: URL) async throws -> MediaLink {
        let (_, response) = try await HTTP.loggedIn.data(for: HTTP.pageRequest(url))
        guard let finalURL = response.url else { throw KeepsakeError.unsupportedLink }
        if let link = MediaLink.parse(url: finalURL), link != .redirect(finalURL) { return link }
        if let next = URLComponents(url: finalURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "next" })?.value,
           let nextURL = URL(string: next, relativeTo: home)?.absoluteURL,
           let link = MediaLink.parse(url: nextURL) {
            return link
        }
        throw KeepsakeError.unsupportedLink
    }

    // MARK: - Networking

    private static func bundle(from media: [String: Any], fallbackTitle: String, source: URL) throws -> MediaBundle {
        let items = MetaMediaParser.items(from: media)
        if items.isEmpty { throw KeepsakeError.noMedia }
        return MediaBundle(platform: .instagram,
                           title: MetaMediaParser.username(of: media).map { "@\($0)" } ?? fallbackTitle,
                           caption: MetaMediaParser.caption(of: media), sourceURL: source, items: items)
    }

    private static func apiRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(HTTP.desktopUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(webAppID, forHTTPHeaderField: "X-IG-App-ID")
        request.setValue("129477", forHTTPHeaderField: "X-ASBD-ID")
        request.setValue("0", forHTTPHeaderField: "X-IG-WWW-Claim")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("https://www.instagram.com/", forHTTPHeaderField: "Referer")
        request.setValue("https://www.instagram.com", forHTTPHeaderField: "Origin")
        if let csrf = cookie("csrftoken") { request.setValue(csrf, forHTTPHeaderField: "X-CSRFToken") }
        return request
    }

    private static func api(_ path: String, query: [URLQueryItem] = []) async throws -> [String: Any] {
        var components = URLComponents(string: "https://www.instagram.com/api/v1/" + path)!
        if !query.isEmpty { components.queryItems = query }
        return try await send(apiRequest(components.url!))
    }

    private static func send(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await HTTP.loggedIn.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let message = (json?["message"] as? String) ?? ""

        if message.contains("checkpoint") || message.contains("challenge") { throw KeepsakeError.checkpoint }
        if message.contains("login_required") || status == 401 { throw KeepsakeError.loginRequired }
        if status == 429 || message.lowercased().contains("wait a few minutes") { throw KeepsakeError.rateLimited }
        if status == 404 || message.contains("Media not found") { throw KeepsakeError.notFound }
        guard let json else { throw KeepsakeError.loginRequired }
        if status == 403 { throw isLoggedIn ? KeepsakeError.notFound : KeepsakeError.loginRequired }
        guard (200..<300).contains(status) else {
            throw KeepsakeError.server(message.isEmpty ? "Instagram returned an error (\(status))." : message)
        }
        return json
    }
}
