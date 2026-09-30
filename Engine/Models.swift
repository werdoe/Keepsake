import Foundation
import SwiftUI

enum Platform: String, Codable, CaseIterable, Identifiable {
    case instagram
    case threads
    case facebook
    case tiktok

    var id: String { rawValue }

    var name: String {
        switch self {
        case .instagram: return "Instagram"
        case .threads: return "Threads"
        case .facebook: return "Facebook"
        case .tiktok: return "TikTok"
        }
    }

    /// Generic SF Symbols (not the platforms' logos).
    var symbol: String {
        switch self {
        case .instagram: return "camera"
        case .threads: return "at"
        case .facebook: return "person.2"
        case .tiktok: return "music.note"
        }
    }

    var tint: Color {
        switch self {
        case .instagram: return Color(red: 0.86, green: 0.25, blue: 0.47)
        case .threads: return Color.primary
        case .facebook: return Color(red: 0.10, green: 0.47, blue: 0.95)
        case .tiktok: return Color(red: 0.93, green: 0.18, blue: 0.36)
        }
    }

    var supportedKinds: String {
        switch self {
        case .instagram: return "Posts, reels, stories, highlights, profiles"
        case .threads: return "Posts and profiles (private ones after logging in)"
        case .facebook: return "Reels, videos and photos (private and friends-only after logging in)"
        case .tiktok: return "Videos without watermark, photo slideshows, sounds"
        }
    }

    /// Where to log in, and which cookie proves you're logged in.
    var loginURL: URL? {
        switch self {
        case .instagram: return URL(string: "https://www.instagram.com/accounts/login/")
        case .threads: return URL(string: "https://www.threads.com/login")
        case .facebook: return URL(string: "https://www.facebook.com/login")
        case .tiktok: return nil
        }
    }

    var cookieDomains: [String] {
        switch self {
        case .instagram: return ["instagram.com"]
        case .threads: return ["threads.com", "threads.net"]
        case .facebook: return ["facebook.com"]
        case .tiktok: return ["tiktok.com"]
        }
    }

    var sessionCookieName: String {
        switch self {
        case .facebook: return "c_user"
        default: return "sessionid"
        }
    }

    var loginHelp: String {
        switch self {
        case .instagram: return "Stories, highlights and private accounts you follow"
        case .threads: return "Private accounts you follow"
        case .facebook: return "Friends-only and private posts, and stories"
        case .tiktok: return ""
        }
    }
}

/// One concrete file (or pair of files) that can be saved.
struct MediaSource: Hashable, Codable {
    var url: URL
    /// Separate audio stream (DASH). When set, `url` is video-only and the two get merged.
    var audioURL: URL?
    var width: Int
    var height: Int
    var codec: String?
    /// Extra request headers some CDNs require (TikTok needs its cookies and a Referer).
    var headers: [String: String]?

    var pixelCount: Int { width * height }

    /// "1080p", "4K" etc. based on the shorter side.
    var resolutionLabel: String? {
        let short = min(width, height)
        guard short > 0 else { return nil }
        switch short {
        case 2100...: return "4K"
        case 1400..<2100: return "1440p"
        case 1000..<1400: return "1080p"
        case 700..<1000: return "720p"
        default: return "\(short)p"
        }
    }
}

struct MediaItem: Identifiable, Hashable {
    enum Kind: String, Codable { case photo, video }

    let id = UUID()
    let kind: Kind
    let thumbnailURL: URL
    /// Always-playable file (progressive MP4 / full JPEG).
    let standard: MediaSource
    /// Higher-quality alternative, if the platform offers one.
    let best: MediaSource?
    /// A ready-made audio-only stream (DASH audio, TikTok sound), if known.
    var audio: MediaSource?

    func source(for preference: QualityPreference) -> MediaSource {
        if preference == .best, let best, best.pixelCount > standard.pixelCount || best.audioURL != nil {
            return best
        }
        return standard
    }

    /// Where "Save Audio" can get sound from without downloading the video.
    var directAudio: MediaSource? {
        if let audio { return audio }
        if let audioURL = best?.audioURL {
            return MediaSource(url: audioURL, width: 0, height: 0, codec: "mp4a", headers: best?.headers)
        }
        return nil
    }

    var aspectRatio: CGFloat {
        guard standard.width > 0, standard.height > 0 else { return 4.0 / 5.0 }
        return CGFloat(standard.width) / CGFloat(standard.height)
    }
}

/// Everything found behind one link.
struct MediaBundle: Identifiable {
    let id = UUID()
    let platform: Platform
    let title: String
    let caption: String?
    let sourceURL: URL
    let items: [MediaItem]
    /// Stable identity of the post ("instagram:post:CODE") for duplicate detection.
    var key: String?
    /// When the post was published, if known.
    var date: Date?

    var summary: String {
        let photos = items.filter { $0.kind == .photo }.count
        let videos = items.count - photos
        var parts: [String] = []
        if photos > 0 { parts.append("\(photos) photo\(photos == 1 ? "" : "s")") }
        if videos > 0 { parts.append("\(videos) video\(videos == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    var hashtags: [String] {
        guard let caption else { return [] }
        var tags: [String] = []
        for word in caption.split(whereSeparator: { $0.isWhitespace || $0.isNewline }) where word.hasPrefix("#") && word.count > 1 {
            let tag = String(word).trimmingCharacters(in: .punctuationCharacters.subtracting(CharacterSet(charactersIn: "#_")))
            if tag.count > 1, !tags.contains(tag) { tags.append(tag) }
        }
        return tags
    }
}

enum KeepsakeError: LocalizedError, Equatable {
    case unsupportedLink
    case loginRequired
    case loginRequiredFor(Platform)
    case checkpoint
    case notFound
    case rateLimited
    case noMedia
    case wifiOnly
    case offline
    case photosPermission
    case downloadFailed
    case timedOut
    case server(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedLink:
            return "That link isn't from Instagram, Threads, Facebook or TikTok, or it doesn't point to a post."
        case .loginRequired:
            return "Instagram wants you to be logged in for this. Log in from Settings › Accounts."
        case .loginRequiredFor(let platform):
            return "\(platform.name) only shows this to logged-in people. Log in to \(platform.name) in Settings › Accounts, then try again."
        case .checkpoint:
            return "Instagram wants to confirm it's you. Open Settings › Accounts, log in again and finish the check."
        case .notFound:
            return "Couldn't find it. It may be deleted, expired (stories last 24 hours), or from a private account."
        case .rateLimited:
            return "The platform is limiting requests right now. Try again in a few minutes."
        case .noMedia:
            return "This post doesn't have any photos or videos to save."
        case .wifiOnly:
            return "Wi-Fi only is on. Connect to Wi-Fi, or allow mobile data in Settings."
        case .offline:
            return "You're offline. Check your connection and try again."
        case .photosPermission:
            return "Keepsake can't add to your Photos. Allow it in Settings › Keepsake › Photos."
        case .downloadFailed:
            return "The download didn't finish. Try again."
        case .timedOut:
            return "The page took too long to load. Try again."
        case .server(let message):
            return message
        }
    }

    var needsLogin: Platform? {
        switch self {
        case .loginRequired, .checkpoint: return .instagram
        case .loginRequiredFor(let platform): return platform
        default: return nil
        }
    }

    /// Errors that will hit every remaining item too, so a batch should stop.
    static func stopsBatch(_ error: Error) -> Bool {
        guard let e = error as? KeepsakeError else { return false }
        return e == .wifiOnly || e == .photosPermission || e == .offline
    }

    /// Maps low-level networking errors to something a person can act on.
    static func from(_ error: Error) -> Error {
        if error is KeepsakeError { return error }
        if let urlError = error as? URLError {
            if urlError.networkUnavailableReason == .cellular || urlError.networkUnavailableReason == .expensive
                || urlError.networkUnavailableReason == .constrained {
                return KeepsakeError.wifiOnly
            }
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return KeepsakeError.offline
            case .timedOut, .cannotConnectToHost, .cannotFindHost:
                return KeepsakeError.downloadFailed
            default:
                break
            }
        }
        return error
    }
}
