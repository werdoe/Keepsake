import Foundation

/// Facebook embeds public reels' and videos' playback data (an HD MP4 plus a DASH manifest)
/// in the page for logged-out visitors. Photos fall back to the page's preview image.
enum FacebookExtractor {
    static func media(from url: URL) async throws -> MediaBundle {
        let pageURL = normalise(url)
        let (html, finalURL) = try await HTTP.fetchPage(pageURL)
        let targetID = videoID(in: finalURL) ?? videoID(in: pageURL)
        let scripts = HTTP.jsonScripts(in: html)
        let thumbnail = HTTP.metaContent("og:image", in: html).flatMap(URL.init(string:))
        let title = HTTP.metaContent("og:title", in: html).map(cleanTitle) ?? "Facebook"

        if let item = videoItem(in: scripts, targetID: targetID, thumbnail: thumbnail) {
            return MediaBundle(platform: .facebook, title: title, caption: nil, sourceURL: finalURL, items: [item])
        }
        if let photo = photoItem(in: scripts, fallback: thumbnail) {
            return MediaBundle(platform: .facebook, title: title, caption: nil, sourceURL: finalURL, items: [photo])
        }
        if html.contains("login_form") || finalURL.path.contains("/login") {
            throw KeepsakeError.server("Facebook only shows this to logged-in people, so it can't be saved. Public reels, videos and photos work.")
        }
        throw KeepsakeError.notFound
    }

    // MARK: - Video

    private static func videoItem(in scripts: [Any], targetID: String?, thumbnail: URL?) -> MediaItem? {
        var deliveries: [[String: Any]] = []
        var representationSets: [[String: Any]] = []
        for json in scripts {
            deliveries += HTTP.findDictionaries(in: json) { $0["browser_native_hd_url"] != nil || $0["browser_native_sd_url"] != nil }
            representationSets += HTTP.findDictionaries(in: json) { $0["representations"] is [[String: Any]] && $0["video_id"] != nil }
        }
        guard !deliveries.isEmpty else { return nil }

        // Pages also preload other reels, so prefer the one the link points to.
        let delivery = deliveries.first { targetID != nil && HTTP.string($0["id"]) == targetID } ?? deliveries[0]
        let id = HTTP.string(delivery["id"])

        guard let progressive = HTTP.url(delivery["browser_native_hd_url"]) ?? HTTP.url(delivery["browser_native_sd_url"]) else {
            return nil
        }

        // DASH streams: from the JSON list if present, otherwise from the manifest string.
        var reps: [DashRepresentation] = []
        if let set = representationSets.first(where: { HTTP.string($0["video_id"]) == id }),
           let list = set["representations"] as? [[String: Any]] {
            reps = DASH.representations(fromJSON: list)
        }
        if reps.isEmpty, let manifest = delivery["dash_manifest_xml_string"] as? String {
            reps = DASH.representations(fromManifest: manifest)
        }

        // The progressive HD file is usually 720p; DASH tells us its real size.
        let allVideos = reps.filter(\.isVideo)
        let guessHeight = HTTP.url(delivery["browser_native_hd_url"]) != nil ? 1280 : 640
        let tallest = allVideos.max { $0.height < $1.height }
        let standardHeight = min(guessHeight, tallest?.height ?? guessHeight)
        let aspect = tallest.map { Double($0.width) / Double(max($0.height, 1)) } ?? (9.0 / 16.0)
        let standard = MediaSource(url: progressive, width: Int(Double(standardHeight) * aspect), height: standardHeight)

        var best = DASH.bestSource(from: reps)
        if let candidate = best, candidate.pixelCount <= standard.pixelCount { best = nil }

        return MediaItem(kind: .video, thumbnailURL: thumbnail ?? progressive, standard: standard, best: best)
    }

    // MARK: - Photo

    private static func photoItem(in scripts: [Any], fallback: URL?) -> MediaItem? {
        var candidates: [MediaSource] = []
        for json in scripts {
            for dict in HTTP.findDictionaries(in: json, where: { $0["viewer_image"] is [String: Any] || $0["photo_image"] is [String: Any] }) {
                let image = (dict["viewer_image"] ?? dict["photo_image"]) as? [String: Any]
                if let uri = HTTP.url(image?["uri"]) {
                    candidates.append(MediaSource(url: uri, width: HTTP.int(image?["width"]), height: HTTP.int(image?["height"])))
                }
            }
        }
        if let best = candidates.max(by: { $0.pixelCount < $1.pixelCount }) {
            return MediaItem(kind: .photo, thumbnailURL: best.url, standard: best, best: nil)
        }
        if let fallback {
            return MediaItem(kind: .photo, thumbnailURL: fallback,
                             standard: MediaSource(url: fallback, width: 0, height: 0), best: nil)
        }
        return nil
    }

    // MARK: - URLs

    private static func normalise(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        if let host = components.host?.lowercased(), host.hasPrefix("m.") || host.hasPrefix("web.") || host.hasPrefix("mbasic.") {
            components.host = "www.facebook.com"
        }
        // Tracking parameters aren't needed and can change what's served.
        components.queryItems = components.queryItems?.filter { ["v", "fbid", "story_fbid", "id", "set"].contains($0.name) }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        return components.url ?? url
    }

    /// Video ID from /reel/ID, /videos/ID, /watch?v=ID, /watch/?v=ID.
    static func videoID(in url: URL) -> String? {
        let parts = url.pathComponents.filter { $0 != "/" }
        for (index, part) in parts.enumerated() where ["reel", "videos", "video"].contains(part) && index + 1 < parts.count {
            if MediaLink.isDigits(parts[index + 1]) { return parts[index + 1] }
        }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        if let v = query?.first(where: { $0.name == "v" })?.value, MediaLink.isDigits(v) { return v }
        return nil
    }

    private static func cleanTitle(_ title: String) -> String {
        let trimmed = title.components(separatedBy: " | ").first ?? title
        return trimmed.count > 60 ? String(trimmed.prefix(57)) + "…" : trimmed
    }
}
