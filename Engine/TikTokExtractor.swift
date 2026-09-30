import Foundation

/// TikTok videos and photo slideshows. TikTok shows a browser check before the real page,
/// so the page is loaded in a hidden web view. The web player's file (`playAddr`) has no
/// watermark; `bitrateInfo` lists higher-quality versions.
enum TikTokExtractor {
    static func media(from url: URL) async throws -> MediaBundle {
        let targetID = itemID(in: url)
        let result = try await WebCapture.capture(url, platform: .tiktok, timeout: 30) { json in
            item(in: json, id: targetID) != nil
        }
        let id = targetID ?? itemID(in: result.finalURL)
        guard let item = item(in: result.json, id: id) else {
            throw KeepsakeError.server("TikTok didn't return this video. It may be private, removed, or age-restricted.")
        }

        let headers = [
            "Referer": "https://www.tiktok.com/",
            "Cookie": Accounts.cookieHeader(from: result.cookies.filter { $0.domain.hasSuffix("tiktok.com") }),
            "User-Agent": HTTP.desktopUserAgent,
        ]
        let author = (item["author"] as? [String: Any])?["uniqueId"] as? String
        let caption = (item["desc"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let created = HTTP.int(item["createTime"])
        let music = item["music"] as? [String: Any]
        let sound = HTTP.url(music?["playUrl"]).map {
            MediaSource(url: $0, width: 0, height: 0, codec: "mp4a", headers: headers)
        }
        let itemIdentifier = HTTP.string(item["id"]) ?? id ?? UUID().uuidString
        let source = URL(string: "https://www.tiktok.com/@\(author ?? "_")/video/\(itemIdentifier)") ?? url

        var items: [MediaItem] = []
        if let imagePost = item["imagePost"] as? [String: Any],
           let images = imagePost["images"] as? [[String: Any]], !images.isEmpty {
            for image in images {
                let imageURL = image["imageURL"] as? [String: Any]
                guard let first = (imageURL?["urlList"] as? [String])?.first, let url = URL(string: first) else { continue }
                let photo = MediaSource(url: url, width: HTTP.int(image["imageWidth"]), height: HTTP.int(image["imageHeight"]),
                                        headers: headers)
                items.append(MediaItem(kind: .photo, thumbnailURL: url, standard: photo, best: nil, audio: sound))
            }
        } else if let video = item["video"] as? [String: Any], let play = HTTP.url(video["playAddr"]) {
            let standard = MediaSource(url: play, width: HTTP.int(video["width"]), height: HTTP.int(video["height"]),
                                       codec: video["codecType"] as? String, headers: headers)
            let cover = HTTP.url(video["originCover"]) ?? HTTP.url(video["cover"]) ?? play
            items.append(MediaItem(kind: .video, thumbnailURL: cover, standard: standard,
                                   best: bestVersion(video, headers: headers, than: standard), audio: sound))
        }
        if items.isEmpty { throw KeepsakeError.noMedia }

        return MediaBundle(platform: .tiktok, title: author.map { "@\($0)" } ?? "TikTok", caption: caption,
                           sourceURL: source, items: items, key: "tiktok:\(itemIdentifier)",
                           date: created > 0 ? Date(timeIntervalSince1970: TimeInterval(created)) : nil)
    }

    /// The largest version in `bitrateInfo` that iPhones play natively (H.264 / HEVC).
    private static func bestVersion(_ video: [String: Any], headers: [String: String], than standard: MediaSource) -> MediaSource? {
        let versions = (video["bitrateInfo"] as? [[String: Any]] ?? []).compactMap { info -> (MediaSource, Int)? in
            let codec = (info["CodecType"] as? String ?? "").lowercased()
            guard codec.contains("h264") || codec.contains("h265") || codec.contains("hevc") || codec.contains("bytevc1") else { return nil }
            guard let play = info["PlayAddr"] as? [String: Any],
                  let first = (play["UrlList"] as? [String])?.first, let url = URL(string: first) else { return nil }
            let source = MediaSource(url: url, width: HTTP.int(play["Width"]), height: HTTP.int(play["Height"]),
                                     codec: codec, headers: headers)
            return (source, HTTP.int(info["Bitrate"]))
        }
        guard let best = versions.max(by: { ($0.0.pixelCount, $0.1) < ($1.0.pixelCount, $1.1) })?.0,
              best.pixelCount > standard.pixelCount else { return nil }
        return best
    }

    /// Finds the post's `itemStruct` in TikTok's page data.
    private static func item(in json: [Any], id: String?) -> [String: Any]? {
        for blob in json {
            guard let root = blob as? [String: Any] else { continue }
            let scope = root["__DEFAULT_SCOPE__"] as? [String: Any] ?? root
            if let detail = scope["webapp.video-detail"] as? [String: Any],
               let item = (detail["itemInfo"] as? [String: Any])?["itemStruct"] as? [String: Any],
               id == nil || HTTP.string(item["id"]) == id {
                return item
            }
            // API responses (e.g. item detail) use the same item shape.
            if let item = (root["itemInfo"] as? [String: Any])?["itemStruct"] as? [String: Any],
               id == nil || HTTP.string(item["id"]) == id {
                return item
            }
        }
        return nil
    }

    /// ID from /video/ID or /photo/ID. Short links (vm.tiktok.com) have none until redirected.
    static func itemID(in url: URL) -> String? {
        let parts = url.pathComponents
        for (index, part) in parts.enumerated() where (part == "video" || part == "photo") && index + 1 < parts.count {
            if MediaLink.isDigits(parts[index + 1]) { return parts[index + 1] }
        }
        return nil
    }
}
