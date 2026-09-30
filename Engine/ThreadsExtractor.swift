import Foundation

/// Threads serves public posts' full media data inside the page, even when logged out.
enum ThreadsExtractor {
    static func post(shortcode: String, url: URL) async throws -> MediaBundle {
        let pageURL = canonicalURL(for: url, shortcode: shortcode)
        let (html, finalURL) = try await HTTP.fetchPage(pageURL)

        for json in HTTP.jsonScripts(in: html) {
            let matches = HTTP.findDictionaries(in: json, limit: 1) { dict in
                (dict["code"] as? String) == shortcode
                    && (dict["image_versions2"] != nil || dict["carousel_media"] != nil || dict["video_versions"] != nil)
            }
            if let media = matches.first {
                let items = MetaMediaParser.items(from: media)
                if items.isEmpty { throw KeepsakeError.noMedia }
                return MediaBundle(platform: .threads,
                                   title: MetaMediaParser.username(of: media).map { "@\($0)" } ?? "Threads post",
                                   caption: MetaMediaParser.caption(of: media), sourceURL: finalURL, items: items)
            }
        }

        // Text-only posts have no media; anything else we couldn't read is treated as not found.
        if html.contains(shortcode) { throw KeepsakeError.noMedia }
        throw KeepsakeError.notFound
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
