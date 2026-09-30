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

/// User preferences, stored in the shared app group so the share sheet follows them too.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let store = AppGroup.defaults

    @Published var quality: QualityPreference { didSet { store.set(quality.rawValue, forKey: Keys.quality) } }
    @Published var wifiOnly: Bool { didSet { store.set(wifiOnly, forKey: Keys.wifiOnly) } }
    @Published var saveToAlbum: Bool { didSet { store.set(saveToAlbum, forKey: Keys.saveToAlbum) } }
    @Published var shareAutoSave: Bool { didSet { store.set(shareAutoSave, forKey: Keys.shareAutoSave) } }
    @Published var liveActivities: Bool { didSet { store.set(liveActivities, forKey: Keys.liveActivities) } }
    @Published var haptics: Bool { didSet { store.set(haptics, forKey: Keys.haptics) } }
    @Published var keepHistory: Bool { didSet { store.set(keepHistory, forKey: Keys.keepHistory) } }
    @Published var hasOnboarded: Bool { didSet { store.set(hasOnboarded, forKey: Keys.hasOnboarded) } }

    private enum Keys {
        static let quality = "quality"
        static let wifiOnly = "wifiOnly"
        static let saveToAlbum = "saveToAlbum"
        static let shareAutoSave = "shareAutoSave"
        static let liveActivities = "liveActivities"
        static let haptics = "haptics"
        static let keepHistory = "keepHistory"
        static let hasOnboarded = "hasOnboarded"
    }

    private init() {
        store.register(defaults: [
            Keys.quality: QualityPreference.best.rawValue,
            Keys.wifiOnly: false,
            Keys.saveToAlbum: false,
            Keys.shareAutoSave: true,
            Keys.liveActivities: true,
            Keys.haptics: true,
            Keys.keepHistory: true,
            Keys.hasOnboarded: false,
        ])
        quality = QualityPreference(rawValue: store.string(forKey: Keys.quality) ?? "") ?? .best
        wifiOnly = store.bool(forKey: Keys.wifiOnly)
        saveToAlbum = store.bool(forKey: Keys.saveToAlbum)
        shareAutoSave = store.bool(forKey: Keys.shareAutoSave)
        liveActivities = store.bool(forKey: Keys.liveActivities)
        haptics = store.bool(forKey: Keys.haptics)
        keepHistory = store.bool(forKey: Keys.keepHistory)
        hasOnboarded = store.bool(forKey: Keys.hasOnboarded)
    }
}
