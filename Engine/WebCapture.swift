import Foundation
import UIKit
import WebKit

/// Loads a page in an invisible web view (with your saved login, if any) and collects the
/// JSON the site loads for itself: embedded page data plus its own fetch/XHR responses.
/// This works where a plain request can't: logged-in Facebook/Threads pages, and TikTok's
/// "Please wait…" browser check.
@MainActor
final class WebCapture: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    struct Result {
        var json: [Any]
        var cookies: [HTTPCookie]
        var finalURL: URL
    }

    /// A view the web view can live in while it loads (pages don't run properly outside a window).
    /// The app and the share extension set this.
    static weak var hostView: UIView?

    private var webView: WKWebView?
    private var json: [Any] = []
    private var continuation: CheckedContinuation<Result, Error>?
    private var isDone: (([Any]) -> Bool)?
    private var urlCondition: ((URL) -> Bool)?
    private var timeoutTask: Task<Void, Never>?
    private var finished = false

    /// Loads `url` and returns once `until` is satisfied by the collected JSON, or after `timeout`.
    static func capture(_ url: URL, platform: Platform, timeout: TimeInterval = 25,
                        until: @escaping ([Any]) -> Bool) async throws -> Result {
        let capture = WebCapture()
        return try await capture.run(url: url, platform: platform, timeout: timeout, until: until, urlCondition: nil)
    }

    /// Follows a short/share link (including JavaScript redirects) and returns where it lands.
    static func resolve(_ url: URL, platform: Platform, timeout: TimeInterval = 15,
                        until: @escaping (URL) -> Bool) async throws -> URL {
        let capture = WebCapture()
        let result = try await capture.run(url: url, platform: platform, timeout: timeout,
                                           until: { _ in false }, urlCondition: until)
        return result.finalURL
    }

    private func run(url: URL, platform: Platform, timeout: TimeInterval, until: @escaping ([Any]) -> Bool,
                     urlCondition: ((URL) -> Bool)?) async throws -> Result {
        let config = WKWebViewConfiguration()
        let store = WKWebsiteDataStore.nonPersistent()
        config.websiteDataStore = store
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.allowsInlineMediaPlayback = true
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: Self.hookScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.add(WeakMessageHandler(self), name: "keepsake")
        config.userContentController = controller

        // Bring the saved login into this private web view.
        for cookie in Accounts.cookies(for: platform) {
            await store.httpCookieStore.setCookie(cookie)
        }

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        webView.customUserAgent = HTTP.desktopUserAgent
        webView.navigationDelegate = self
        webView.isUserInteractionEnabled = false
        webView.alpha = 0.01
        if let host = Self.hostView {
            host.insertSubview(webView, at: 0)
        }
        self.webView = webView
        self.isDone = until
        self.urlCondition = urlCondition

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Result, Error>) in
                self.continuation = continuation
                webView.load(URLRequest(url: url))
                self.timeoutTask = Task { [weak self] in
                    let deadline = Date().addingTimeInterval(timeout)
                    // Poll for URL-based completion (redirects); otherwise just wait out the timeout.
                    while Date() < deadline {
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        guard let self, !self.finished else { return }
                        if let condition = self.urlCondition, let current = self.webView?.url, condition(current) {
                            break
                        }
                    }
                    await self?.finish(error: nil)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(error: CancellationError()) }
        }
    }

    // MARK: - Messages from the page

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !finished, let text = message.body as? String else { return }
        // Responses can be megabytes; parse off the main thread.
        Task.detached(priority: .userInitiated) { [weak self] in
            let parsed = WebCapture.parseJSONText(text)
            await self?.received(parsed)
        }
    }

    private func received(_ parsed: [Any]) {
        guard !finished, !parsed.isEmpty else { return }
        json.append(contentsOf: parsed)
        if isDone?(json) == true { finish(error: nil) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if json.isEmpty { finish(error: error) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if json.isEmpty { finish(error: error) }
    }

    private func finish(error: Error?) {
        guard !finished, let continuation else { return }
        finished = true
        timeoutTask?.cancel()
        let webView = self.webView
        let collected = json
        Task { @MainActor in
            let cookies = await webView?.configuration.websiteDataStore.httpCookieStore.allCookies() ?? []
            let finalURL = webView?.url ?? URL(string: "about:blank")!
            webView?.stopLoading()
            webView?.configuration.userContentController.removeAllScriptMessageHandlers()
            webView?.removeFromSuperview()
            if let error, collected.isEmpty {
                continuation.resume(throwing: error is CancellationError ? error : KeepsakeError.from(error))
            } else {
                continuation.resume(returning: Result(json: collected, cookies: cookies, finalURL: finalURL))
            }
        }
        self.webView = nil
    }

    // MARK: - Parsing

    /// Page data and API responses can be plain JSON, several JSON documents separated by
    /// newlines (Facebook), or prefixed with "for (;;);".
    nonisolated static func parseJSONText(_ raw: String) -> [Any] {
        var text = raw
        if text.hasPrefix("for (;;);") { text.removeFirst("for (;;);".count) }
        if let data = text.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) {
            return [json]
        }
        return text.split(separator: "\n").compactMap { line in
            guard line.count > 50, let data = line.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data)
        }
    }

    /// Wraps fetch/XHR and scans embedded JSON scripts, forwarding anything that looks like media data.
    private static let hookScript = """
    (function () {
      var pattern = /image_versions2|video_versions|progressive_url|representations|browser_native|playAddr|itemStruct|playable_url|viewer_image|photo_image|imagePost/;
      function post(t) {
        try {
          if (typeof t === 'string' && t.length > 200 && pattern.test(t)) {
            window.webkit.messageHandlers.keepsake.postMessage(t);
          }
        } catch (e) {}
      }
      var originalFetch = window.fetch;
      if (originalFetch) {
        window.fetch = function () {
          return originalFetch.apply(this, arguments).then(function (response) {
            try { response.clone().text().then(post).catch(function () {}); } catch (e) {}
            return response;
          });
        };
      }
      var originalSend = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.send = function () {
        this.addEventListener('load', function () {
          try { if (!this.responseType || this.responseType === 'text') post(this.responseText); } catch (e) {}
        });
        return originalSend.apply(this, arguments);
      };
      function scan() {
        var scripts = document.querySelectorAll('script[type="application/json"], script#__UNIVERSAL_DATA_FOR_REHYDRATION__');
        for (var i = 0; i < scripts.length; i++) {
          var s = scripts[i];
          if (!s.__keepsakeSeen) { s.__keepsakeSeen = true; post(s.textContent); }
        }
      }
      document.addEventListener('DOMContentLoaded', scan);
      window.addEventListener('load', scan);
      setInterval(scan, 800);
    })();
    """
}

/// Avoids a retain cycle between the web view's content controller and the capture.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
