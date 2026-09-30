import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Entry point for "Share › Keepsake". Hosts the SwiftUI card and reads the shared link.
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        // The hidden browser used for TikTok and logged-in pages needs a view to live in.
        WebCapture.hostView = view
        // Let the app see which shared container the share sheet is using.
        AppGroup.recordShareExtensionRun()
        HistoryStore.migrateStrandedData()

        model.close = { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }

        let host = UIHostingController(rootView: ShareCardView(model: model))
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)

        Task { await loadSharedText() }
    }

    private func loadSharedText() async {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
        var candidates: [String] = []

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
               let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                candidates.append(url.absoluteString)
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
               let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                candidates.append(text)
            }
        }
        // Some apps also put the link in the item's text.
        for item in extensionContext?.inputItems as? [NSExtensionItem] ?? [] {
            if let text = item.attributedContentText?.string { candidates.append(text) }
        }

        let match = candidates.first { MediaLink.parse($0) != nil }
        await MainActor.run { model.start(with: match) }
    }
}
