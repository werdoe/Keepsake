import Foundation

/// The shared container the app and the share extension both use for settings,
/// login cookies and download history.
enum AppGroup {
    static let fallbackIdentifier = "group.com.rai.igsaver"

    /// SideStore/AltStore rename app groups when they sign the app and write the real
    /// name into `ALTAppGroups` in Info.plist, so read it from there first.
    static let identifier: String = {
        if let groups = Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String],
           let first = groups.first, !first.isEmpty {
            return first
        }
        return fallbackIdentifier
    }()

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    /// True when the app and extension can actually see each other's data.
    static var isAvailable: Bool { containerURL != nil }

    static let defaults: UserDefaults = {
        if isAvailable, let shared = UserDefaults(suiteName: identifier) { return shared }
        return .standard
    }()

    static let cookieStorage: HTTPCookieStorage = {
        isAvailable ? HTTPCookieStorage.sharedCookieStorage(forGroupContainerIdentifier: identifier) : .shared
    }()

    /// Folder for history and thumbnails.
    static var dataDirectory: URL {
        let base = containerURL
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Keepsake", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
