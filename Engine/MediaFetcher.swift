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
            case .threadsPost(let code, let url):
                return try await ThreadsExtractor.post(shortcode: code, url: url)
            case .facebook(let url):
                return try await FacebookExtractor.media(from: url)
            case .redirect(let url):
                guard depth < 2 else { throw KeepsakeError.unsupportedLink }
                if link.platform == .facebook {
                    let (_, finalURL) = try await HTTP.fetchPage(url)
                    if let resolved = MediaLink.parse(url: finalURL), resolved != link {
                        return try await fetch(resolved, depth: depth + 1)
                    }
                    return try await FacebookExtractor.media(from: finalURL)
                }
                return try await fetch(try await InstagramExtractor.resolve(url), depth: depth + 1)
            }
        } catch {
            throw KeepsakeError.from(error)
        }
    }
}
