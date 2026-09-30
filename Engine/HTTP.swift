import Foundation

/// Shared networking setup: browser identity, login cookies and JSON/HTML helpers.
enum HTTP {
    static let desktopUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"
    static let htmlAccept = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"

    /// Session that sends the saved Instagram login (used for Instagram API calls).
    static let loggedIn: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = AppGroup.cookieStorage
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    /// Session with no cookies at all. Threads and Facebook serve the full media data
    /// to logged-out page loads, so this is what their extractors use.
    static let anonymous: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    static func pageRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(desktopUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(htmlAccept, forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("document", forHTTPHeaderField: "Sec-Fetch-Dest")
        request.setValue("navigate", forHTTPHeaderField: "Sec-Fetch-Mode")
        return request
    }

    /// Loads a web page as text. Returns the final URL after redirects too.
    static func fetchPage(_ url: URL, session: URLSession = anonymous) async throws -> (html: String, finalURL: URL) {
        let (data, response) = try await session.data(for: pageRequest(url))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        if status == 404 { throw KeepsakeError.notFound }
        if status == 429 { throw KeepsakeError.rateLimited }
        guard let html = String(data: data, encoding: .utf8) else { throw KeepsakeError.notFound }
        return (html, response.url ?? url)
    }

    /// Parses every `<script type="application/json">` block in a page. Meta's sites
    /// (Instagram, Threads, Facebook) put their server-rendered data there.
    static func jsonScripts(in html: String) -> [Any] {
        var results: [Any] = []
        var searchRange = html.startIndex..<html.endIndex
        while let open = html.range(of: "<script type=\"application/json\"", range: searchRange) {
            guard let tagEnd = html.range(of: ">", range: open.upperBound..<html.endIndex),
                  let close = html.range(of: "</script>", range: tagEnd.upperBound..<html.endIndex) else { break }
            let body = html[tagEnd.upperBound..<close.lowerBound]
            if body.count > 100, let data = body.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) {
                results.append(json)
            }
            searchRange = close.upperBound..<html.endIndex
        }
        return results
    }

    /// Depth-first search through parsed JSON; returns every dictionary `match` accepts.
    static func findDictionaries(in json: Any, limit: Int = 50, where match: ([String: Any]) -> Bool) -> [[String: Any]] {
        var found: [[String: Any]] = []
        var stack: [Any] = [json]
        while let node = stack.popLast(), found.count < limit {
            if let dict = node as? [String: Any] {
                if match(dict) { found.append(dict) }
                stack.append(contentsOf: dict.values)
            } else if let array = node as? [Any] {
                stack.append(contentsOf: array.reversed())
            }
        }
        return found
    }

    /// `<meta property="og:image" content="...">`
    static func metaContent(_ property: String, in html: String) -> String? {
        let patterns = [
            "<meta property=\"\(property)\" content=\"",
            "<meta name=\"\(property)\" content=\"",
        ]
        for pattern in patterns {
            if let start = html.range(of: pattern),
               let end = html.range(of: "\"", range: start.upperBound..<html.endIndex) {
                return decodeHTMLEntities(String(html[start.upperBound..<end.lowerBound]))
            }
        }
        return nil
    }

    static func decodeHTMLEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#039;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    static func int(_ value: Any?) -> Int {
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

    static func url(_ value: Any?) -> URL? {
        guard let s = value as? String, !s.isEmpty else { return nil }
        return URL(string: s)
    }
}
