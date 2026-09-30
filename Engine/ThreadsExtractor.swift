import Foundation

/// Threads posts and profiles. Threads puts post data (same format as Instagram's API) in the
/// page. We first try a plain request; if Threads doesn't include the data for it, the page is
/// loaded in a hidden web view (with your Threads login, if you added one).
enum ThreadsExtractor {
    // MARK: - Single post

    static func post(shortcode: String, url: URL) async throws -> MediaBundle {
        let pageURL = canonicalURL(for: url, shortcode: shortcode)

        // 1. Plain request.
        var sawPostWithoutMedia = false
        if let (html, finalURL) = try? await HTTP.fetchPage(pageURL) {
            let json = HTTP.jsonScripts(in: html)
            switch find(shortcode: shortcode, in: json) {
            case .media(let media): return try bundle(from: media, shortcode: shortcode, source: finalURL)
            case .textOnly: sawPostWithoutMedia = true
            case .missing: break
            }
        }

        // 2. Real browser engine, with login if available.
        let result = try await WebCapture.capture(pageURL, platform: .threads, timeout: 25) { json in
            if case .media = find(shortcode: shortcode, in: json) { return true }
            return false
        }
        switch find(shortcode: shortcode, in: result.json) {
        case .media(let media):
            return try bundle(from: media, shortcode: shortcode, source: pageURL)
        case .textOnly:
            throw KeepsakeError.noMedia
        case .missing:
            if sawPostWithoutMedia { throw KeepsakeError.noMedia }
            if !Accounts.isLoggedIn(.threads) { throw KeepsakeError.loginRequiredFor(.threads) }
            throw KeepsakeError.notFound
        }
    }

    private enum Lookup {
        case media([String: Any])
        case textOnly
        case missing
    }

    /// Finds the post with this code. Reposts and quote posts keep their media in the inner post.
    private static func find(shortcode: String, in json: [Any]) -> Lookup {
        var foundPost = false
        for blob in json {
            let matches = HTTP.findDictionaries(in: blob, limit: 5) { dict in
                (dict["code"] as? String) == shortcode && (dict["pk"] != nil || dict["id"] != nil)
            }
            for post in matches {
                foundPost = true
                if hasMedia(post) { return .media(post) }
                if let inner = innerPost(of: post), hasMedia(inner) { return .media(inner) }
            }
        }
        return foundPost ? .textOnly : .missing
    }

    private static func hasMedia(_ media: [String: Any]) -> Bool {
        !MetaMediaParser.items(from: media).isEmpty
    }

    /// The quoted or reposted post inside a Threads post, if any.
    private static func innerPost(of post: [String: Any]) -> [String: Any]? {
        let info = (post["text_post_app_info"] as? [String: Any])?["share_info"] as? [String: Any]
        return (info?["quoted_post"] as? [String: Any])
            ?? (info?["reposted_post"] as? [String: Any])
            ?? (info?["quoted_attachment_post"] as? [String: Any])
    }

    private static func bundle(from media: [String: Any], shortcode: String, source: URL) throws -> MediaBundle {
        let items = MetaMediaParser.items(from: media)
        if items.isEmpty { throw KeepsakeError.noMedia }
        return MediaBundle(platform: .threads,
                           title: MetaMediaParser.username(of: media).map { "@\($0)" } ?? "Threads post",
                           caption: MetaMediaParser.caption(of: media), sourceURL: source, items: items,
                           key: "threads:\(shortcode)", date: MetaMediaParser.date(of: media))
    }

    // MARK: - Profile (latest posts)

    static func profile(username: String, limit: Int = 12) async throws -> MediaBundle {
        let pageURL = URL(string: "https://www.threads.com/@\(username)")!
        var json: [Any] = []
        if let (html, _) = try? await HTTP.fetchPage(pageURL) {
            json = HTTP.jsonScripts(in: html)
        }
        var posts = profilePosts(in: json, username: username)
        if posts.isEmpty {
            let result = try await WebCapture.capture(pageURL, platform: .threads, timeout: 20) { json in
                profilePosts(in: json, username: username).count >= 6
            }
            posts = profilePosts(in: result.json, username: username)
        }
        let items = posts.prefix(limit).flatMap { MetaMediaParser.items(from: $0) }
        if items.isEmpty {
            throw Accounts.isLoggedIn(.threads) ? KeepsakeError.noMedia : KeepsakeError.loginRequiredFor(.threads)
        }
        return MediaBundle(platform: .threads, title: "@\(username)", caption: "Latest posts",
                           sourceURL: pageURL, items: Array(items), key: nil)
    }

    private static func profilePosts(in json: [Any], username: String) -> [[String: Any]] {
        var seen = Set<String>()
        var posts: [[String: Any]] = []
        for blob in json {
            for post in HTTP.findDictionaries(in: blob, limit: 300, where: { dict in
                dict["code"] is String && (dict["image_versions2"] != nil || dict["carousel_media"] != nil)
                    && MetaMediaParser.username(of: dict)?.lowercased() == username.lowercased()
            }) {
                guard let code = post["code"] as? String, seen.insert(code).inserted, hasMedia(post) else { continue }
                posts.append(post)
            }
        }
        return posts.sorted { HTTP.int($0["taken_at"]) > HTTP.int($1["taken_at"]) }
    }

    /// Threads moved from threads.net to threads.com; normalise so the request doesn't bounce.
    private static func canonicalURL(for url: URL, shortcode: String) -> URL {
        let parts = url.pathComponents.filter { $0 != "/" }
        if let user = parts.first(where: { $0.hasPrefix("@") }) {
            return URL(string: "https://www.threads.com/\(user)/post/\(shortcode)") ?? url
        }
        return URL(string: "https://www.threads.com/t/\(shortcode)") ?? url
    }
}
