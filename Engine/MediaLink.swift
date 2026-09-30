import Foundation

/// A recognised link from one of the supported platforms.
enum MediaLink: Equatable {
    case instagramPost(shortcode: String, url: URL)
    case instagramStory(username: String, storyID: String?)
    case instagramHighlight(id: String, itemID: String?)
    /// instagram.com/share/... or facebook share links; followed to find the real post.
    case redirect(URL)
    case threadsPost(shortcode: String, url: URL)
    case facebook(URL)

    var platform: Platform {
        switch self {
        case .instagramPost, .instagramStory, .instagramHighlight: return .instagram
        case .threadsPost: return .threads
        case .facebook: return .facebook
        case .redirect(let url): return Self.platform(forHost: url.host) ?? .instagram
        }
    }

    // MARK: - Parsing

    /// Finds the first supported link in pasted or shared text.
    static func parse(_ text: String) -> MediaLink? {
        for url in extractURLs(from: text) {
            if let link = parse(url: url) { return link }
        }
        return nil
    }

    static func extractURLs(from text: String) -> [URL] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var urls: [URL] = []
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            urls = detector.matches(in: trimmed, options: [], range: range).compactMap(\.url)
        }
        if urls.isEmpty, !trimmed.contains(" "), let url = URL(string: trimmed.hasPrefix("http") ? trimmed : "https://" + trimmed) {
            urls = [url]
        }
        return urls.filter { platform(forHost: $0.host) != nil }
    }

    static func platform(forHost host: String?) -> Platform? {
        guard let host = host?.lowercased() else { return nil }
        func matches(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        if matches("instagram.com") || matches("instagr.am") { return .instagram }
        if matches("threads.net") || matches("threads.com") { return .threads }
        if matches("facebook.com") || matches("fb.watch") || matches("fb.com") || matches("fb.me") { return .facebook }
        return nil
    }

    static func parse(url: URL) -> MediaLink? {
        guard let platform = platform(forHost: url.host) else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []

        switch platform {
        case .instagram:
            return parseInstagram(url: url, parts: parts, query: query)
        case .threads:
            // threads.com/@user/post/CODE, threads.net/t/CODE
            for (index, part) in parts.enumerated() where (part == "post" || part == "t") && index + 1 < parts.count {
                let code = parts[index + 1]
                if isShortcode(code) { return .threadsPost(shortcode: code, url: url) }
            }
            return nil
        case .facebook:
            let host = url.host?.lowercased() ?? ""
            if host.contains("fb.watch") || host.contains("fb.me") || parts.first == "share" {
                return .redirect(url)
            }
            return parts.isEmpty && query.isEmpty ? nil : .facebook(url)
        }
    }

    private static func parseInstagram(url: URL, parts: [String], query: [URLQueryItem]) -> MediaLink? {
        guard let first = parts.first?.lowercased() else { return nil }
        switch first {
        case "stories":
            guard parts.count >= 2 else { return nil }
            if parts[1].lowercased() == "highlights" {
                guard parts.count >= 3, isDigits(parts[2]) else { return nil }
                return .instagramHighlight(id: parts[2], itemID: storyMediaID(from: query))
            }
            let storyID = parts.count >= 3 && isDigits(parts[2]) ? parts[2] : nil
            return .instagramStory(username: parts[1], storyID: storyID)
        case "s":
            guard parts.count >= 2, let decoded = decodeBase64(parts[1]), decoded.hasPrefix("highlight:") else { return nil }
            let id = String(decoded.dropFirst("highlight:".count))
            return isDigits(id) ? .instagramHighlight(id: id, itemID: storyMediaID(from: query)) : nil
        case "share":
            return .redirect(url)
        default:
            let kinds: Set<String> = ["p", "reel", "reels", "tv"]
            for i in 0..<min(parts.count - 1, 2) where kinds.contains(parts[i].lowercased()) {
                if isShortcode(parts[i + 1]) { return .instagramPost(shortcode: parts[i + 1], url: url) }
            }
            return nil
        }
    }

    // MARK: - Helpers

    /// Instagram and Threads shortcodes encode the numeric media ID in base64.
    static func mediaID(fromShortcode code: String) -> String? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        var id: UInt64 = 0
        for ch in code.prefix(11) {
            guard let value = alphabet.firstIndex(of: ch) else { return nil }
            let (shifted, o1) = id.multipliedReportingOverflow(by: 64)
            let (sum, o2) = shifted.addingReportingOverflow(UInt64(value))
            if o1 || o2 { return nil }
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
