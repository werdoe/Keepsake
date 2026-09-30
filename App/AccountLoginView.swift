import SwiftUI
import WebKit

/// The platform's own login page in a web view. Your password goes only to the platform;
/// Keepsake keeps the session cookies it hands back (shared with the share sheet via the app group).
struct AccountLoginView: View {
    let platform: Platform
    var onLoggedIn: () -> Void = {}
    @Environment(\.dismiss) var dismiss
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            Group {
                if let url = platform.loginURL {
                    LoginWebView(platform: platform, url: url, isLoading: $isLoading) {
                        onLoggedIn()
                        dismiss()
                    }
                    .ignoresSafeArea(edges: .bottom)
                } else {
                    ContentUnavailableView("No login needed", systemImage: "checkmark.circle",
                                           description: Text("\(platform.name) works without logging in."))
                }
            }
            .overlay { if isLoading && platform.loginURL != nil { ProgressView().controlSize(.large) } }
            .navigationTitle("Log in to \(platform.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

private struct LoginWebView: UIViewRepresentable {
    let platform: Platform
    let url: URL
    @Binding var isLoading: Bool
    var onLoggedIn: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(platform: platform, isLoading: $isLoading, onLoggedIn: onLoggedIn) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        config.websiteDataStore.httpCookieStore.add(context.coordinator)
        context.coordinator.cookieStore = config.websiteDataStore.httpCookieStore
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.cookieStore?.remove(coordinator)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKHTTPCookieStoreObserver {
        let platform: Platform
        var isLoading: Binding<Bool>
        let onLoggedIn: () -> Void
        weak var cookieStore: WKHTTPCookieStore?
        private var finished = false

        init(platform: Platform, isLoading: Binding<Bool>, onLoggedIn: @escaping () -> Void) {
            self.platform = platform
            self.isLoading = isLoading
            self.onLoggedIn = onLoggedIn
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoading.wrappedValue = false
            checkForSession()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            isLoading.wrappedValue = false
        }

        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            checkForSession()
        }

        private func checkForSession() {
            guard !finished, let store = cookieStore else { return }
            let platform = self.platform
            store.getAllCookies { [weak self] cookies in
                guard let self, !self.finished else { return }
                let mine = cookies.filter { cookie in platform.cookieDomains.contains { cookie.domain.hasSuffix($0) } }
                guard mine.contains(where: { $0.name == platform.sessionCookieName && !$0.value.isEmpty }) else { return }
                self.finished = true
                Accounts.store(mine, for: platform)
                // Let the site finish setting its remaining cookies before closing.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    store.getAllCookies { later in
                        Accounts.store(later, for: platform)
                        self.onLoggedIn()
                    }
                }
            }
        }
    }
}

enum AccountSession {
    /// Copies cookies the sites refreshed inside the app's web views into the shared store.
    @MainActor
    static func syncFromWebView() async {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        for platform in Platform.allCases where Accounts.isLoggedIn(platform) {
            Accounts.store(cookies, for: platform)
        }
    }

    @MainActor
    static func logOut(_ platform: Platform) async {
        Accounts.logOut(platform)
        let store = WKWebsiteDataStore.default()
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        let mine = records.filter { record in
            platform.cookieDomains.contains { record.displayName.contains($0.components(separatedBy: ".").first ?? $0) }
        }
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: mine)
    }
}
