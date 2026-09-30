import SwiftUI
import WebKit

/// Shows Instagram's own login page. Your password goes straight to Instagram; the app only
/// keeps the session cookie Instagram hands back, the same way Safari would.
struct LoginView: View {
    var onLoggedIn: () -> Void
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            InstagramWebView(onLoggedIn: {
                onLoggedIn()
                dismiss()
            })
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("Log in to Instagram")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

private struct InstagramWebView: UIViewRepresentable {
    var onLoggedIn: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onLoggedIn: onLoggedIn) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        config.websiteDataStore.httpCookieStore.add(context.coordinator)
        context.coordinator.cookieStore = config.websiteDataStore.httpCookieStore
        webView.load(URLRequest(url: URL(string: "https://www.instagram.com/accounts/login/")!))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.cookieStore?.remove(coordinator)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKHTTPCookieStoreObserver {
        let onLoggedIn: () -> Void
        weak var cookieStore: WKHTTPCookieStore?
        private var finished = false

        init(onLoggedIn: @escaping () -> Void) { self.onLoggedIn = onLoggedIn }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            checkForSession()
        }

        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            checkForSession()
        }

        private func checkForSession() {
            guard !finished, let store = cookieStore else { return }
            store.getAllCookies { [weak self] cookies in
                guard let self, !self.finished else { return }
                let igCookies = cookies.filter { $0.domain.contains("instagram.com") }
                guard igCookies.contains(where: { $0.name == "sessionid" && !$0.value.isEmpty }) else { return }
                self.finished = true
                igCookies.forEach { HTTPCookieStorage.shared.setCookie($0) }
                DispatchQueue.main.async { self.onLoggedIn() }
            }
        }
    }
}

enum InstagramSession {
    /// Copies Instagram cookies from the web view's store into the store URLSession uses,
    /// in case they drifted apart (e.g. Instagram refreshed them inside the login page).
    @MainActor
    static func syncFromWebView() async {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        for cookie in cookies where cookie.domain.contains("instagram.com") {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
    }

    @MainActor
    static func logOut() async {
        let storage = HTTPCookieStorage.shared
        for cookie in storage.cookies ?? [] where cookie.domain.contains("instagram.com") {
            storage.deleteCookie(cookie)
        }
        let store = WKWebsiteDataStore.default()
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        let igRecords = records.filter { $0.displayName.contains("instagram") }
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: igRecords)
    }
}
