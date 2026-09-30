import Combine
import Foundation
import UIKit

/// Works through links that were queued while offline (or off Wi-Fi with "Wi-Fi only" on),
/// as soon as a suitable connection is back.
@MainActor
final class QueueProcessor: ObservableObject {
    static let shared = QueueProcessor()

    @Published private(set) var isRunning = false
    @Published private(set) var currentLink: String?
    /// Number of links saved in the last run, for a confirmation message.
    @Published private(set) var lastRunSaved = 0

    private var cancellable: AnyCancellable?
    private let queue = OfflineQueue.shared

    private init() {}

    /// Starts watching the network; call once at launch.
    func start() {
        guard cancellable == nil else { return }
        cancellable = NetworkMonitor.shared.$kind
            .removeDuplicates()
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                Task { await self?.run() }
            }
    }

    var canRunNow: Bool {
        let kind = NetworkMonitor.shared.kind
        if kind == .offline { return false }
        if AppSettings.shared.wifiOnly && kind != .wifi { return false }
        return true
    }

    func run() async {
        queue.reload()
        guard !isRunning, canRunNow, !queue.items.isEmpty else { return }
        isRunning = true
        var saved = 0
        var background = UIBackgroundTaskIdentifier.invalid
        background = UIApplication.shared.beginBackgroundTask(withName: "Keepsake queue") {
            UIApplication.shared.endBackgroundTask(background)
        }
        for item in queue.items {
            guard canRunNow else { break }
            currentLink = item.link
            do {
                let bundle = try await MediaFetcher.fetch(item.link)
                _ = try await SavePipeline.save(bundle.items, from: bundle, downloader: BackgroundDownloader.shared) { _ in }
                queue.remove(item)
                saved += 1
            } catch {
                let mapped = KeepsakeError.from(error)
                if OfflineQueue.isConnectionProblem(mapped) { break }
                queue.markFailed(item, error: mapped.localizedDescription)
            }
        }
        currentLink = nil
        lastRunSaved = saved
        isRunning = false
        UIApplication.shared.endBackgroundTask(background)
    }
}
