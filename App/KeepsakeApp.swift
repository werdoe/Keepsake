import SwiftUI

@main
struct KeepsakeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings = AppSettings.shared
    @StateObject private var history = HistoryStore.shared
    @StateObject private var model = SaveModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(history)
                .environmentObject(model)
        }
    }
}
