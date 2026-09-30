import SwiftUI

struct RootView: View {
    enum Tab: Hashable { case save, library, settings }

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: SaveModel
    @EnvironmentObject private var history: HistoryStore
    @Environment(\.scenePhase) private var scenePhase

    @State private var tab: Tab = .save
    @State private var loginPlatform: Platform?

    var body: some View {
        TabView(selection: $tab) {
            HomeView(selectedTab: $tab, loginPlatform: $loginPlatform)
                .tabItem { Label("Save", systemImage: "arrow.down.circle.fill") }
                .tag(Tab.save)
            LibraryView(selectedTab: $tab)
                .tabItem { Label("Library", systemImage: "square.stack.fill") }
                .tag(Tab.library)
            SettingsView(loginPlatform: $loginPlatform)
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(Tab.settings)
        }
        .tint(Brand.blue)
        .background { CaptureHost().frame(width: 1, height: 1).allowsHitTesting(false) }
        .sheet(item: $loginPlatform) { platform in
            AccountLoginView(platform: platform) {
                model.show("Logged in to \(platform.name)")
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { !settings.hasOnboarded },
            set: { settings.hasOnboarded = !$0 }
        )) {
            OnboardingView()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            becameActive()
        }
        .onAppear { becameActive() }
        .onOpenURL { url in handle(url) }
    }

    private func becameActive() {
        history.reload()
        FileStore.collectInbox()
        model.handlePendingPasteSave()
        Task { await AccountSession.syncFromWebView() }
    }

    /// keepsake://save?url=<link>   keepsake://open?url=<link>   keepsake://library   keepsake://paste
    private func handle(_ url: URL) {
        guard url.scheme == "keepsake" else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        switch url.host {
        case "library":
            tab = .library
        case "paste":
            tab = .save
            AppGroup.defaults.set(Date(), forKey: SaveModel.pendingPasteKey)
            model.handlePendingPasteSave()
        default:
            tab = .save
            if let link = components?.queryItems?.first(where: { $0.name == "url" })?.value {
                model.paste(link, autoSave: url.host == "save")
            }
        }
    }
}

/// An invisible view the hidden capture browser can live in while it loads pages.
private struct CaptureHost: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        view.isUserInteractionEnabled = false
        view.clipsToBounds = true
        WebCapture.hostView = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
