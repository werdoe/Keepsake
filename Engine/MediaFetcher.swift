import Foundation

/// Turns any supported link into a `MediaBundle`.
enum MediaFetcher {
    static func fetch(_ text: String) async throws -> MediaBundle {
        guard let link = MediaLink.parse(text) else { throw KeepsakeError.unsupportedLink }
        return try await fetch(link)
    }

    static func fetch(_ link: MediaLink, depth: Int = 0) async throws -> MediaBundle {
        do {
            switch link {
            case .instagramPost(let code, let url):
                return try await InstagramExtractor.post(shortcode: code, url: url)
            case .instagramStory(let username, let storyID):
                return try await InstagramExtractor.stories(username: username, storyID: storyID)
            case .instagramHighlight(let id, let itemID):
                return try await InstagramExtractor.highlight(id: id, itemID: itemID)
            case .instagramProfile(let username):
                return try await InstagramExtractor.latestPosts(username: username)
            case .threadsPost(let code, let url):
                return try await ThreadsExtractor.post(shortcode: code, url: url)
            case .threadsProfile(let username):
                return try await ThreadsExtractor.profile(username: username)
            case .facebook(let url):
                return try await FacebookExtractor.media(from: url)
            case .tiktok(let url):
                return try await TikTokExtractor.media(from: url)
            case .redirect(let url):
                guard depth < 2 else { throw KeepsakeError.unsupportedLink }
                let resolved = try await resolve(url, platform: link.platform)
                return try await fetch(resolved, depth: depth + 1)
            }
        } catch {
            throw KeepsakeError.from(error)
        }
    }

    /// Follows a share/short link to the post it points to.
    static func resolve(_ url: URL, platform: Platform) async throws -> MediaLink {
        func usable(_ candidate: URL) -> MediaLink? {
            guard let link = MediaLink.parse(url: candidate) else { return nil }
            if case .redirect = link { return nil }
            return link
        }

        // 1. Ordinary HTTP redirects.
        if platform == .instagram, let link = try? await InstagramExtractor.resolve(url) {
            return link
        }
        if let (_, finalURL) = try? await HTTP.fetchPage(url, session: HTTP.anonymous) {
            if let link = usable(finalURL) { return link }
            // Logged-out Instagram redirects can land on the login page with the post in ?next=
            if let next = URLComponents(url: finalURL, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "next" })?.value,
               let nextURL = URL(string: next, relativeTo: finalURL)?.absoluteURL,
               let link = usable(nextURL) {
                return link
            }
        }

        // 2. JavaScript redirects: let a real browser engine follow them.
        let landed = try await WebCapture.resolve(url, platform: platform) { usable($0) != nil }
        if let link = usable(landed) { return link }
        if platform == .facebook { return .facebook(landed) }
        throw KeepsakeError.server("Couldn't open that share link. Try copying the link again from the post.")
    }
}
