import Foundation
import SwiftUI

enum Platform: String, Codable, CaseIterable, Identifiable {
    case instagram
    case threads
    case facebook

    var id: String { rawValue }

    var name: String {
        switch self {
        case .instagram: return "Instagram"
        case .threads: return "Threads"
        case .facebook: return "Facebook"
        }
    }

    /// Generic SF Symbols (not the platforms' logos).
    var symbol: String {
        switch self {
        case .instagram: return "camera"
        case .threads: return "at"
        case .facebook: return "person.2"
        }
    }

    var tint: Color {
        switch self {
        case .instagram: return Color(red: 0.86, green: 0.25, blue: 0.47)
        case .threads: return Color.primary
        case .facebook: return Color(red: 0.10, green: 0.47, blue: 0.95)
        }
    }

    var supportedKinds: String {
        switch self {
        case .instagram: return "Posts, reels, stories, highlights"
        case .threads: return "Public posts: photos and videos"
        case .facebook: return "Public reels, videos and photos"
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

    func source(for preference: QualityPreference) -> MediaSource {
        if preference == .best, let best, best.pixelCount > standard.pixelCount || best.audioURL != nil {
            return best
        }
        return standard
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

    var summary: String {
        let photos = items.filter { $0.kind == .photo }.count
        let videos = items.count - photos
        var parts: [String] = []
        if photos > 0 { parts.append("\(photos) photo\(photos == 1 ? "" : "s")") }
        if videos > 0 { parts.append("\(videos) video\(videos == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}

enum KeepsakeError: LocalizedError, Equatable {
    case unsupportedLink
    case loginRequired
    case checkpoint
    case notFound
    case rateLimited
    case noMedia
    case wifiOnly
    case offline
    case photosPermission
    case downloadFailed
    case server(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedLink:
            return "That link isn't from Instagram, Threads or Facebook, or it doesn't point to a post."
        case .loginRequired:
            return "Instagram wants you to be logged in for this. Log in from Settings › Accounts."
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
        case .server(let message):
            return message
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
