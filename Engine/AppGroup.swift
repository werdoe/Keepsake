import Foundation

/// The shared container the app, the share extension and the widgets use for settings,
/// login cookies, the Library and the offline queue.
///
/// SideStore/AltStore rename app groups when they sign (they append your team ID), and don't
/// always update every extension's Info.plist. So we try every place the real name can be
/// found and use the first group this process can actually open.
enum AppGroup {
    static let fallbackIdentifier = "group.com.rai.igsaver"

    static let identifier: String = {
        let candidates = candidateIdentifiers()
        for id in candidates where FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) != nil {
            return id
        }
        return candidates.first ?? fallbackIdentifier
    }()

    static func candidateIdentifiers() -> [String] {
        var ids: [String] = []
        func add(_ list: [String]?) {
            for id in list ?? [] where !id.isEmpty && !ids.contains(id) { ids.append(id) }
        }
        let own = Bundle.main
        let containingApp = containingAppBundle
        add(own.object(forInfoDictionaryKey: "ALTAppGroups") as? [String])
        add(containingApp?.object(forInfoDictionaryKey: "ALTAppGroups") as? [String])
        let ownProfile = ProvisioningProfile(bundle: own)
        let appProfile = containingApp.flatMap(ProvisioningProfile.init(bundle:))
        add(ownProfile?.appGroups)
        add(appProfile?.appGroups)
        if let team = ownProfile?.teamID ?? appProfile?.teamID {
            add([fallbackIdentifier + "." + team])
        }
        add([fallbackIdentifier])
        return ids
    }

    /// For an extension (Keepsake.app/PlugIns/X.appex), the app that contains it.
    private static var containingAppBundle: Bundle? {
        let url = Bundle.main.bundleURL
        guard url.pathExtension == "appex" else { return nil }
        return Bundle(url: url.deletingLastPathComponent().deletingLastPathComponent())
    }

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    /// True when the app, share sheet and widgets can see each other's data.
    static var isAvailable: Bool { containerURL != nil }

    static let defaults: UserDefaults = {
        if isAvailable, let shared = UserDefaults(suiteName: identifier) { return shared }
        return .standard
    }()

    static let cookieStorage: HTTPCookieStorage = {
        isAvailable ? HTTPCookieStorage.sharedCookieStorage(forGroupContainerIdentifier: identifier) : .shared
    }()

    /// This process's own (unshared) folder, used when the group isn't available.
    static var privateDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Keepsake", isDirectory: true)
    }

    /// Folder for history, thumbnails, collections and the queue.
    static var dataDirectory: URL {
        let dir = containerURL?.appendingPathComponent("Keepsake", isDirectory: true) ?? privateDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Records which group this process uses, so the app can spot a mismatch with the share sheet.
    static func recordShareExtensionRun() {
        defaults.set(Date(), forKey: "shareExtensionLastRun")
        defaults.set(identifier, forKey: "shareExtensionGroup")
    }
}

/// Reads the embedded.mobileprovision SideStore puts in each signed bundle.
struct ProvisioningProfile {
    let appGroups: [String]
    let teamID: String?

    init?(bundle: Bundle) {
        guard let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else { return nil }
        let plistData = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else {
            return nil
        }
        let entitlements = plist["Entitlements"] as? [String: Any]
        appGroups = entitlements?["com.apple.security.application-groups"] as? [String] ?? []
        teamID = (plist["TeamIdentifier"] as? [String])?.first
    }
}
