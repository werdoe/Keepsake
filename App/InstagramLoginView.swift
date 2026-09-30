import SwiftUI
import WebKit

/// Instagram's own login page in a web view. The password goes only to Instagram; Keepsake keeps
/// the session cookie it hands back (shared with the share sheet through the app group).
struct InstagramLoginView: View {
    var onLoggedIn: () -> Void
    @Environment(\.dismiss) var dismiss
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            InstagramWebView(isLoading: $isLoading) {
                onLoggedIn()
                dismiss()
            }
            .ignoresSafeArea(edges: .bottom)
            .overlay { if isLoading { ProgressView().controlSize(.large) } }
            .navigationTitle("Log in to Instagram")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

private struct InstagramWebView: UIViewRepresentable {
    @Binding var isLoading: Bool
    var onLoggedIn: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(isLoading: $isLoading, onLoggedIn: onLoggedIn) }

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
        var isLoading: Binding<Bool>
        let onLoggedIn: () -> Void
        weak var cookieStore: WKHTTPCookieStore?
        private var finished = false

        init(isLoading: Binding<Bool>, onLoggedIn: @escaping () -> Void) {
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
            store.getAllCookies { [weak self] cookies in
                guard let self, !self.finished else { return }
                let instagram = cookies.filter { $0.domain.contains("instagram.com") }
                guard instagram.contains(where: { $0.name == "sessionid" && !$0.value.isEmpty }) else { return }
                self.finished = true
                instagram.forEach { AppGroup.cookieStorage.setCookie($0) }
                DispatchQueue.main.async { self.onLoggedIn() }
            }
        }
    }
}

enum InstagramSession {
    /// Copies cookies Instagram refreshed inside the web view into the shared store.
    @MainActor
    static func syncFromWebView() async {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        let instagram = cookies.filter { $0.domain.contains("instagram.com") }
        guard instagram.contains(where: { $0.name == "sessionid" }) else { return }
        instagram.forEach { AppGroup.cookieStorage.setCookie($0) }
    }

    @MainActor
    static func logOut() async {
        let storage = AppGroup.cookieStorage
        for cookie in storage.cookies ?? [] where cookie.domain.contains("instagram.com") {
            storage.deleteCookie(cookie)
        }
        let store = WKWebsiteDataStore.default()
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                               for: records.filter { $0.displayName.contains("instagram") })
    }
}
