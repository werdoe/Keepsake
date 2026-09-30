import Foundation
import SwiftUI

enum QualityPreference: String, CaseIterable, Identifiable {
    /// Highest resolution available, merging separate video and audio streams when needed.
    case best
    /// The ready-made file the platform serves to browsers. Faster and smaller.
    case standard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .best: return "Best available"
        case .standard: return "Standard"
        }
    }

    var detail: String {
        switch self {
        case .best: return "Highest resolution and bitrate. Takes a little longer."
        case .standard: return "Faster, smaller files."
        }
    }
}

/// Where saved photos and videos go.
enum SaveDestination: String, CaseIterable, Identifiable {
    case photos
    case files
    case both

    var id: String { rawValue }

    var title: String {
        switch self {
        case .photos: return "Photos"
        case .files: return "Files"
        case .both: return "Both"
        }
    }

    var detail: String {
        switch self {
        case .photos: return "Saves to your Photos library."
        case .files: return "Saves to Files › On My iPhone › Keepsake, in a folder per platform and account."
        case .both: return "Saves to Photos and keeps a copy in Files › On My iPhone › Keepsake."
        }
    }

    var includesPhotos: Bool { self != .files }
    var includesFiles: Bool { self != .photos }
}

/// User preferences, stored in the shared app group so the share sheet and widgets follow them too.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let store = AppGroup.defaults

    @Published var quality: QualityPreference { didSet { store.set(quality.rawValue, forKey: Keys.quality) } }
    @Published var destination: SaveDestination { didSet { store.set(destination.rawValue, forKey: Keys.destination) } }
    @Published var wifiOnly: Bool { didSet { store.set(wifiOnly, forKey: Keys.wifiOnly) } }
    @Published var saveToAlbum: Bool { didSet { store.set(saveToAlbum, forKey: Keys.saveToAlbum) } }
    @Published var albumPerAccount: Bool { didSet { store.set(albumPerAccount, forKey: Keys.albumPerAccount) } }
    @Published var keepOriginalDate: Bool { didSet { store.set(keepOriginalDate, forKey: Keys.keepOriginalDate) } }
    @Published var embedCaption: Bool { didSet { store.set(embedCaption, forKey: Keys.embedCaption) } }
    @Published var shareAutoSave: Bool { didSet { store.set(shareAutoSave, forKey: Keys.shareAutoSave) } }
    @Published var liveActivities: Bool { didSet { store.set(liveActivities, forKey: Keys.liveActivities) } }
    @Published var haptics: Bool { didSet { store.set(haptics, forKey: Keys.haptics) } }
    @Published var keepHistory: Bool { didSet { store.set(keepHistory, forKey: Keys.keepHistory) } }
    @Published var lockLibrary: Bool { didSet { store.set(lockLibrary, forKey: Keys.lockLibrary) } }
    @Published var hasOnboarded: Bool { didSet { store.set(hasOnboarded, forKey: Keys.hasOnboarded) } }

    private enum Keys {
        static let quality = "quality"
        static let destination = "destination"
        static let wifiOnly = "wifiOnly"
        static let saveToAlbum = "saveToAlbum"
        static let albumPerAccount = "albumPerAccount"
        static let keepOriginalDate = "keepOriginalDate"
        static let embedCaption = "embedCaption"
        static let shareAutoSave = "shareAutoSave"
        static let liveActivities = "liveActivities"
        static let haptics = "haptics"
        static let keepHistory = "keepHistory"
        static let lockLibrary = "lockLibrary"
        static let hasOnboarded = "hasOnboarded"
    }

    private init() {
        store.register(defaults: [
            Keys.quality: QualityPreference.best.rawValue,
            Keys.destination: SaveDestination.photos.rawValue,
            Keys.wifiOnly: false,
            Keys.saveToAlbum: false,
            Keys.albumPerAccount: false,
            Keys.keepOriginalDate: false,
            Keys.embedCaption: true,
            Keys.shareAutoSave: true,
            Keys.liveActivities: true,
            Keys.haptics: true,
            Keys.keepHistory: true,
            Keys.lockLibrary: false,
            Keys.hasOnboarded: false,
        ])
        quality = QualityPreference(rawValue: store.string(forKey: Keys.quality) ?? "") ?? .best
        destination = SaveDestination(rawValue: store.string(forKey: Keys.destination) ?? "") ?? .photos
        wifiOnly = store.bool(forKey: Keys.wifiOnly)
        saveToAlbum = store.bool(forKey: Keys.saveToAlbum)
        albumPerAccount = store.bool(forKey: Keys.albumPerAccount)
        keepOriginalDate = store.bool(forKey: Keys.keepOriginalDate)
        embedCaption = store.bool(forKey: Keys.embedCaption)
        shareAutoSave = store.bool(forKey: Keys.shareAutoSave)
        liveActivities = store.bool(forKey: Keys.liveActivities)
        haptics = store.bool(forKey: Keys.haptics)
        keepHistory = store.bool(forKey: Keys.keepHistory)
        lockLibrary = store.bool(forKey: Keys.lockLibrary)
        hasOnboarded = store.bool(forKey: Keys.hasOnboarded)
    }
}
