import SwiftUI

struct RootView: View {
    enum Tab: Hashable { case save, library, settings }

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: SaveModel
    @EnvironmentObject private var history: HistoryStore
    @Environment(\.scenePhase) private var scenePhase

    @State private var tab: Tab = .save
    @State private var showAccounts = false

    var body: some View {
        TabView(selection: $tab) {
            HomeView(selectedTab: $tab, showAccounts: $showAccounts)
                .tabItem { Label("Save", systemImage: "arrow.down.circle.fill") }
                .tag(Tab.save)
            LibraryView(selectedTab: $tab)
                .tabItem { Label("Library", systemImage: "square.stack.fill") }
                .tag(Tab.library)
            SettingsView(showAccounts: $showAccounts)
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(Tab.settings)
        }
        .tint(Brand.blue)
        .sheet(isPresented: $showAccounts) {
            InstagramLoginView { }
        }
        .fullScreenCover(isPresented: Binding(
            get: { !settings.hasOnboarded },
            set: { settings.hasOnboarded = !$0 }
        )) {
            OnboardingView()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            history.reload()
            Task { await InstagramSession.syncFromWebView() }
        }
        .onOpenURL { url in handle(url) }
    }

    /// keepsake://save?url=<link>  (usable from Shortcuts)
    private func handle(_ url: URL) {
        guard url.scheme == "keepsake" else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        tab = .save
        if let link = components?.queryItems?.first(where: { $0.name == "url" })?.value {
            model.paste(link, autoSave: url.host == "save")
        }
    }
}
