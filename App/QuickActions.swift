import SwiftUI
import UIKit

/// Home screen quick actions (long-press the app icon): Paste & Save, Batch Save, Library.
/// They're declared in Info.plist and routed as keepsake:// links.
@MainActor
final class QuickActionRouter: ObservableObject {
    static let shared = QuickActionRouter()
    @Published var pending: URL?

    func handle(_ item: UIApplicationShortcutItem) {
        let host: String
        switch item.type {
        case "com.raiyanasaral.keepsake.paste": host = "paste"
        case "com.raiyanasaral.keepsake.batch": host = "batch"
        default: host = "library"
        }
        pending = URL(string: "keepsake://\(host)")
    }
}

/// Receives quick actions, both at launch and while running.
final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let item = connectionOptions.shortcutItem {
            Task { @MainActor in QuickActionRouter.shared.handle(item) }
        }
    }

    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        Task { @MainActor in QuickActionRouter.shared.handle(shortcutItem) }
        completionHandler(true)
    }
}
