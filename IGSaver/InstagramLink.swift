import Foundation

/// A parsed Instagram link.
enum InstagramLink: Equatable {
    /// A post, reel or IGTV video, identified by its shortcode (the bit after /p/ or /reel/).
    case post(shortcode: String)
    /// A user's current stories. `storyID` is set when the link points at one specific story.
    case story(username: String, storyID: String?)
    /// A story highlight. `itemID` is set when the link points at one item inside it.
    case highlight(id: String, itemID: String?)
    /// An instagram.com/share/... link, which has to be followed to find the real post.
    case shareRedirect(URL)

    // MARK: - Parsing

    /// Finds the first Instagram link in pasted text (captions and extra words are ignored).
    static func parse(_ text: String) -> InstagramLink? {
        guard let url = extractURL(from: text) else { return nil }
        return parse(url: url)
    }

    static func extractURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            for match in detector.matches(in: trimmed, options: [], range: range) {
                if let url = match.url, isInstagramHost(url.host) { return url }
            }
        }
        // Fallback for text the detector misses, e.g. "instagram.com/p/abc" typed by hand.
        let lower = trimmed.lowercased()
        if lower.contains("instagram.com") || lower.contains("instagr.am") {
            let candidate = lower.hasPrefix("http") ? trimmed : "https://" + trimmed
            if let url = URL(string: candidate), isInstagramHost(url.host) { return url }
        }
        return nil
    }

    static func isInstagramHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "instagram.com" || host.hasSuffix(".instagram.com")
            || host == "instagr.am" || host.hasSuffix(".instagr.am")
    }

    static func parse(url: URL) -> InstagramLink? {
        guard isInstagramHost(url.host) else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard let first = parts.first?.lowercased() else { return nil }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []

        switch first {
        case "stories":
            guard parts.count >= 2 else { return nil }
            if parts[1].lowercased() == "highlights" {
                guard parts.count >= 3, isDigits(parts[2]) else { return nil }
                return .highlight(id: parts[2], itemID: storyMediaID(from: query))
            }
            let username = parts[1]
            let storyID = parts.count >= 3 && isDigits(parts[2]) ? parts[2] : nil
            return .story(username: username, storyID: storyID)

        case "s":
            // instagram.com/s/<base64 of "highlight:12345">?story_media_id=...
            guard parts.count >= 2, let decoded = decodeBase64(parts[1]) else { return nil }
            if decoded.hasPrefix("highlight:") {
                let id = String(decoded.dropFirst("highlight:".count))
                guard isDigits(id) else { return nil }
                return .highlight(id: id, itemID: storyMediaID(from: query))
            }
            return nil

        case "share":
            return .shareRedirect(url)

        default:
            // /p/CODE, /reel/CODE, /reels/CODE, /tv/CODE, or /username/p/CODE, /username/reel/CODE
            let postKinds: Set<String> = ["p", "reel", "reels", "tv"]
            for i in 0..<min(parts.count - 1, 2) where postKinds.contains(parts[i].lowercased()) {
                let code = parts[i + 1]
                if isShortcode(code) { return .post(shortcode: code) }
            }
            return nil
        }
    }

    // MARK: - Helpers

    /// Converts a post shortcode into Instagram's numeric media ID.
    static func mediaID(fromShortcode code: String) -> String? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        var id: UInt64 = 0
        // Links to private posts carry a longer code; only the first 11 characters encode the ID.
        for ch in code.prefix(11) {
            guard let value = alphabet.firstIndex(of: ch) else { return nil }
            let (shifted, overflow1) = id.multipliedReportingOverflow(by: 64)
            let (sum, overflow2) = shifted.addingReportingOverflow(UInt64(value))
            if overflow1 || overflow2 { return nil }
            id = sum
        }
        return id == 0 ? nil : String(id)
    }

    static func isShortcode(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 64 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    static func isDigits(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// story_media_id looks like "3456789_1234" (media pk + owner id); we only need the first part.
    private static func storyMediaID(from query: [URLQueryItem]) -> String? {
        guard let raw = query.first(where: { $0.name == "story_media_id" })?.value else { return nil }
        let pk = raw.split(separator: "_").first.map(String.init) ?? raw
        return isDigits(pk) ? pk : nil
    }

    private static func decodeBase64(_ s: String) -> String? {
        var b64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
