import Foundation

/// Facebook reels, videos, photos and (logged in) stories.
///
/// Logged out, public pages embed playback data (an HD MP4 plus DASH streams). When that's
/// missing and you've logged in, the page is loaded in a hidden web view with your session
/// and the media is read from Facebook's own data responses (`progressive_urls` + DASH).
enum FacebookExtractor {
    static func media(from url: URL) async throws -> MediaBundle {
        let pageURL = normalise(url)
        let isStory = pageURL.path.contains("/stories/")

        if !isStory, let bundle = try? await publicMedia(pageURL) {
            return bundle
        }
        guard Accounts.isLoggedIn(.facebook) else {
            throw KeepsakeError.loginRequiredFor(.facebook)
        }
        return try await loggedInMedia(pageURL, isStory: isStory)
    }

    // MARK: - Logged out

    private static func publicMedia(_ pageURL: URL) async throws -> MediaBundle? {
        let (html, finalURL) = try await HTTP.fetchPage(pageURL)
        let targetID = videoID(in: finalURL) ?? videoID(in: pageURL)
        let scripts = HTTP.jsonScripts(in: html)
        let thumbnail = HTTP.metaContent("og:image", in: html).flatMap(URL.init(string:))
        let title = HTTP.metaContent("og:title", in: html).map(cleanTitle) ?? "Facebook"

        if let item = videoItems(in: scripts, targetID: targetID, thumbnail: thumbnail, onlyTarget: true).first {
            return MediaBundle(platform: .facebook, title: title, caption: nil, sourceURL: finalURL, items: [item],
                               key: "facebook:\(targetID ?? finalURL.path)")
        }
        if !finalURL.path.contains("/login"), !html.contains("login_form"),
           let photo = photoItems(in: scripts, fallback: thumbnail).first {
            return MediaBundle(platform: .facebook, title: title, caption: nil, sourceURL: finalURL, items: [photo],
                               key: "facebook:\(finalURL.path)\(finalURL.query ?? "")")
        }
        return nil
    }

    // MARK: - Logged in

    private static func loggedInMedia(_ pageURL: URL, isStory: Bool) async throws -> MediaBundle {
        let targetID = videoID(in: pageURL)
        let result = try await WebCapture.capture(pageURL, platform: .facebook, timeout: isStory ? 18 : 25) { json in
            // Stop early once the linked video's playback data has arrived.
            guard !isStory, let targetID else { return false }
            return !videoItems(in: json, targetID: targetID, thumbnail: nil, onlyTarget: true).isEmpty
        }
        var items = videoItems(in: result.json, targetID: targetID, thumbnail: nil, onlyTarget: !isStory)
        if items.isEmpty || isStory {
            items += photoItems(in: result.json, fallback: nil).prefix(isStory ? 30 : 1)
        }
        if items.isEmpty {
            throw KeepsakeError.server("Couldn't find media on that Facebook page. It may have been removed, or you may not have access.")
        }
        return MediaBundle(platform: .facebook, title: isStory ? "Facebook story" : "Facebook", caption: nil,
                           sourceURL: result.finalURL.absoluteString == "about:blank" ? pageURL : result.finalURL,
                           items: items, key: "facebook:\(targetID ?? pageURL.path)")
    }

    // MARK: - Video

    /// Collects videos from both of Facebook's shapes:
    /// - `videoDeliveryLegacyFields`: `browser_native_hd_url` / `browser_native_sd_url` + manifest (logged out)
    /// - `videoDeliveryResponseResult`: `progressive_urls` [{progressive_url, metadata.quality}] (logged in)
    /// plus `{video_id, representations}` DASH lists for the best quality.
    static func videoItems(in scripts: [Any], targetID: String?, thumbnail: URL?, onlyTarget: Bool) -> [MediaItem] {
        var progressive: [(id: String, hd: URL?, sd: URL?, manifest: String?)] = []
        var representationSets: [String: [[String: Any]]] = [:]
        var thumbnails: [String: URL] = [:]

        for json in scripts {
            for dict in HTTP.findDictionaries(in: json, limit: 400, where: { d in
                d["browser_native_hd_url"] != nil || d["browser_native_sd_url"] != nil || d["progressive_urls"] is [[String: Any]]
                    || (d["representations"] is [[String: Any]] && d["video_id"] != nil)
                    || (d["preferred_thumbnail"] is [String: Any] && d["id"] != nil)
            }) {
                if let list = dict["representations"] as? [[String: Any]], let vid = HTTP.string(dict["video_id"]) {
                    representationSets[vid] = list
                    continue
                }
                if let thumb = dict["preferred_thumbnail"] as? [String: Any], let id = HTTP.string(dict["id"]),
                   let uri = HTTP.url((thumb["image"] as? [String: Any])?["uri"]) {
                    thumbnails[id] = uri
                }
                guard let id = HTTP.string(dict["id"]) else { continue }
                if let urls = dict["progressive_urls"] as? [[String: Any]] {
                    func url(_ quality: String) -> URL? {
                        urls.first { (($0["metadata"] as? [String: Any])?["quality"] as? String) == quality
                            && $0["failure_reason"] is NSNull || $0["failure_reason"] == nil }
                            .flatMap { HTTP.url($0["progressive_url"]) }
                    }
                    let hd = url("HD"), sd = url("SD") ?? urls.compactMap { HTTP.url($0["progressive_url"]) }.first
                    progressive.append((id, hd, sd, nil))
                } else if dict["browser_native_hd_url"] != nil || dict["browser_native_sd_url"] != nil {
                    progressive.append((id, HTTP.url(dict["browser_native_hd_url"]), HTTP.url(dict["browser_native_sd_url"]),
                                        dict["dash_manifest_xml_string"] as? String))
                }
            }
        }

        // Keep the linked video (pages also preload others), or everything for stories.
        var seen = Set<String>()
        var chosen = progressive.filter { seen.insert($0.id).inserted }
        if let targetID, chosen.contains(where: { $0.id == targetID }) {
            chosen = chosen.filter { $0.id == targetID }
        } else if onlyTarget {
            chosen = Array(chosen.prefix(1))
        }

        return chosen.compactMap { entry in
            guard let file = entry.hd ?? entry.sd else { return nil }
            var reps: [DashRepresentation] = []
            if let list = representationSets[entry.id] { reps = DASH.representations(fromJSON: list) }
            if reps.isEmpty, let manifest = entry.manifest { reps = DASH.representations(fromManifest: manifest) }

            // The progressive HD file is usually 720p; DASH tells us the real shape.
            let tallest = reps.filter(\.isVideo).max { $0.height < $1.height }
            let guessHeight = entry.hd != nil ? 1280 : 640
            let height = min(guessHeight, tallest?.height ?? guessHeight)
            let aspect = tallest.map { Double($0.width) / Double(max($0.height, 1)) } ?? (9.0 / 16.0)
            let standard = MediaSource(url: file, width: Int(Double(height) * aspect), height: height)

            var best = DASH.bestSource(from: reps)
            if let candidate = best, candidate.pixelCount <= standard.pixelCount { best = nil }
            let audio = reps.filter { $0.isAudio && $0.baseURL != nil }.max { $0.bandwidth < $1.bandwidth }
                .map { MediaSource(url: $0.baseURL!, width: 0, height: 0, codec: $0.codecs) }

            let thumb = thumbnails[entry.id] ?? thumbnail ?? file
            return MediaItem(kind: .video, thumbnailURL: thumb, standard: standard, best: best, audio: audio)
        }
    }

    // MARK: - Photo

    private static func photoItems(in scripts: [Any], fallback: URL?) -> [MediaItem] {
        var candidates: [MediaSource] = []
        var seen = Set<URL>()
        for json in scripts {
            for dict in HTTP.findDictionaries(in: json, limit: 200, where: { $0["viewer_image"] is [String: Any] || $0["photo_image"] is [String: Any] }) {
                let image = (dict["viewer_image"] ?? dict["photo_image"]) as? [String: Any]
                if let uri = HTTP.url(image?["uri"]), seen.insert(uri).inserted {
                    candidates.append(MediaSource(url: uri, width: HTTP.int(image?["width"]), height: HTTP.int(image?["height"])))
                }
            }
        }
        if !candidates.isEmpty {
            return candidates.map { MediaItem(kind: .photo, thumbnailURL: $0.url, standard: $0, best: nil) }
        }
        if let fallback {
            return [MediaItem(kind: .photo, thumbnailURL: fallback, standard: MediaSource(url: fallback, width: 0, height: 0), best: nil)]
        }
        return []
    }

    // MARK: - URLs

    private static func normalise(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        if let host = components.host?.lowercased(), host.hasPrefix("m.") || host.hasPrefix("web.") || host.hasPrefix("mbasic.") {
            components.host = "www.facebook.com"
        }
        components.queryItems = components.queryItems?.filter { ["v", "fbid", "story_fbid", "id", "set"].contains($0.name) }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        return components.url ?? url
    }

    /// Video ID from /reel/ID, /videos/ID, /watch?v=ID.
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
