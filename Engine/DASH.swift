import Foundation
import CoreMedia
import VideoToolbox

/// One stream listed in a DASH manifest (video-only or audio-only).
struct DashRepresentation {
    var mimeType: String = ""
    var codecs: String = ""
    var width: Int = 0
    var height: Int = 0
    var bandwidth: Int = 0
    var baseURL: URL?

    var isVideo: Bool { mimeType.hasPrefix("video") }
    var isAudio: Bool { mimeType.hasPrefix("audio") }
}

enum DASH {
    /// Parses an MPD manifest string into its representations.
    /// Relative `BaseURL`s (Reddit uses "DASH_720.mp4") are resolved against `relativeTo`.
    static func representations(fromManifest xml: String, relativeTo base: URL? = nil) -> [DashRepresentation] {
        guard let data = xml.data(using: .utf8) else { return [] }
        let delegate = MPDParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        guard let base else { return delegate.representations }
        return delegate.representations.map { rep in
            var rep = rep
            if let url = rep.baseURL, url.scheme == nil {
                rep.baseURL = URL(string: url.relativeString, relativeTo: base)?.absoluteURL
            }
            return rep
        }
    }

    /// Whether this iPhone can decode AV1 in hardware (iPhone 15 Pro and later).
    static let supportsAV1: Bool = {
        VTIsHardwareDecodeSupported(CMVideoCodecType(0x6176_3031)) // 'av01'
    }()

    static func isPlayable(codec: String) -> Bool {
        let c = codec.lowercased()
        if c.hasPrefix("avc1") || c.hasPrefix("avc3") || c.hasPrefix("hvc1") || c.hasPrefix("hev1") || c.hasPrefix("dvh1") {
            return true
        }
        if c.hasPrefix("av01") { return supportsAV1 }
        return false
    }

    /// Picks the highest-quality video stream this device can play, plus the best audio stream.
    static func bestSource(from reps: [DashRepresentation]) -> MediaSource? {
        let videos = reps.filter { $0.isVideo && $0.baseURL != nil && isPlayable(codec: $0.codecs) }
        guard let video = videos.max(by: { ($0.width * $0.height, $0.bandwidth) < ($1.width * $1.height, $1.bandwidth) }),
              let videoURL = video.baseURL else { return nil }
        let audio = reps
            .filter { $0.isAudio && $0.baseURL != nil && ($0.codecs.isEmpty || $0.codecs.lowercased().hasPrefix("mp4a")) }
            .max { $0.bandwidth < $1.bandwidth }
        return MediaSource(url: videoURL, audioURL: audio?.baseURL, width: video.width, height: video.height, codec: video.codecs)
    }

    /// Parses JSON-style representation lists (Facebook embeds these next to the manifest).
    static func representations(fromJSON list: [[String: Any]]) -> [DashRepresentation] {
        list.map { r in
            DashRepresentation(
                mimeType: r["mime_type"] as? String ?? "",
                codecs: r["codecs"] as? String ?? "",
                width: HTTP.int(r["width"]),
                height: HTTP.int(r["height"]),
                bandwidth: HTTP.int(r["bandwidth"]),
                baseURL: HTTP.url(r["base_url"])
            )
        }
    }
}

private final class MPDParserDelegate: NSObject, XMLParserDelegate {
    var representations: [DashRepresentation] = []

    private var setAttributes: [String: String] = [:]
    private var current: DashRepresentation?
    private var text = ""
    private var inBaseURL = false

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        switch name {
        case "AdaptationSet":
            setAttributes = attributes
        case "Representation":
            var rep = DashRepresentation()
            let contentType = attributes["contentType"] ?? setAttributes["contentType"] ?? ""
            rep.mimeType = attributes["mimeType"] ?? setAttributes["mimeType"]
                ?? (contentType.isEmpty ? "" : contentType + "/mp4")
            rep.codecs = attributes["codecs"] ?? setAttributes["codecs"] ?? ""
            rep.width = Int(attributes["width"] ?? setAttributes["width"] ?? "") ?? 0
            rep.height = Int(attributes["height"] ?? setAttributes["height"] ?? "") ?? 0
            rep.bandwidth = Int(attributes["bandwidth"] ?? "") ?? 0
            current = rep
        case "BaseURL":
            inBaseURL = true
            text = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inBaseURL { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch name {
        case "BaseURL":
            inBaseURL = false
            current?.baseURL = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))
        case "Representation":
            if let rep = current { representations.append(rep) }
            current = nil
        case "AdaptationSet":
            setAttributes = [:]
        default:
            break
        }
    }
}
