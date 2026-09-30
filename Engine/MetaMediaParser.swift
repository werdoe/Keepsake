import Foundation

/// Instagram's API and Threads' page data describe media the same way
/// (image_versions2 / video_versions / carousel_media / video_dash_manifest).
enum MetaMediaParser {
    static func items(from media: [String: Any]) -> [MediaItem] {
        if let carousel = media["carousel_media"] as? [[String: Any]], !carousel.isEmpty {
            return carousel.flatMap { items(from: $0) }
        }
        let images = ((media["image_versions2"] as? [String: Any])?["candidates"] as? [[String: Any]]) ?? []
        guard let image = bestCandidate(images) else { return [] }

        if let videos = media["video_versions"] as? [[String: Any]], !videos.isEmpty, let video = bestCandidate(videos) {
            var best: MediaSource?
            if let manifest = media["video_dash_manifest"] as? String, !manifest.isEmpty,
               let dash = DASH.bestSource(from: DASH.representations(fromManifest: manifest)),
               dash.pixelCount > video.pixelCount {
                best = dash
            }
            return [MediaItem(kind: .video, thumbnailURL: image.url, standard: video, best: best)]
        }
        return [MediaItem(kind: .photo, thumbnailURL: thumbnail(images) ?? image.url, standard: image, best: nil)]
    }

    static func username(of media: [String: Any]) -> String? {
        (media["user"] as? [String: Any])?["username"] as? String
            ?? (media["owner"] as? [String: Any])?["username"] as? String
    }

    static func caption(of media: [String: Any]) -> String? {
        if let caption = media["caption"] as? [String: Any], let text = caption["text"] as? String, !text.isEmpty {
            return text
        }
        return nil
    }

    /// Publish time (`taken_at`, seconds since 1970).
    static func date(of media: [String: Any]) -> Date? {
        let seconds = HTTP.int(media["taken_at"])
        return seconds > 0 ? Date(timeIntervalSince1970: TimeInterval(seconds)) : nil
    }

    private static func bestCandidate(_ list: [[String: Any]]) -> MediaSource? {
        list.compactMap { c -> MediaSource? in
            guard let url = HTTP.url(c["url"]) else { return nil }
            return MediaSource(url: url, audioURL: nil, width: HTTP.int(c["width"]), height: HTTP.int(c["height"]), codec: nil)
        }
        .max { $0.pixelCount < $1.pixelCount }
    }

    /// A smaller candidate for the preview grid (~640px), falling back to the largest.
    private static func thumbnail(_ list: [[String: Any]]) -> URL? {
        let sources = list.compactMap { c -> (URL, Int)? in
            guard let url = HTTP.url(c["url"]) else { return nil }
            return (url, HTTP.int(c["width"]))
        }
        return sources.filter { $0.1 >= 480 }.min { $0.1 < $1.1 }?.0 ?? sources.first?.0
    }
}
