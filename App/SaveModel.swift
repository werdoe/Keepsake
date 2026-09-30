import SwiftUI
import UIKit

/// Drives the Save tab: fetching a link, saving its media, progress and feedback.
@MainActor
final class SaveModel: ObservableObject {
    enum Phase: Equatable { case idle, fetching, ready, saving, done, failed }

    enum ItemState: Equatable {
        case waiting
        case downloading(Double)
        case saved
        case failed(String)
    }

    @Published var linkText = ""
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var bundle: MediaBundle?
    @Published private(set) var itemStates: [UUID: ItemState] = [:]
    @Published private(set) var progress: SaveProgress?
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastError: KeepsakeError?
    @Published private(set) var clipboardHasLink = false
    /// Incremented to trigger haptics.
    @Published private(set) var successTick = 0
    @Published private(set) var errorTick = 0

    private var fetchTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private let liveActivity = LiveActivityController()
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    var detectedPlatform: Platform? { MediaLink.parse(linkText)?.platform }

    // MARK: - Fetch

    func paste(_ text: String, autoSave: Bool = false) {
        linkText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        fetch(autoSave: autoSave)
    }

    func fetch(autoSave: Bool = false) {
        fetchTask?.cancel()
        saveTask?.cancel()
        errorMessage = nil
        lastError = nil
        guard MediaLink.parse(linkText) != nil else {
            if !linkText.isEmpty { fail(KeepsakeError.unsupportedLink) }
            return
        }
        withAnimation(.snappy) {
            phase = .fetching
            bundle = nil
            itemStates = [:]
            progress = nil
        }
        let text = linkText
        fetchTask = Task {
            do {
                let result = try await MediaFetcher.fetch(text)
                guard !Task.isCancelled else { return }
                withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
                    bundle = result
                    itemStates = Dictionary(uniqueKeysWithValues: result.items.map { ($0.id, ItemState.waiting) })
                    phase = .ready
                }
                if autoSave { saveAll() }
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                fail(error)
            }
        }
    }

    // MARK: - Save

    func saveAll() {
        guard let bundle else { return }
        let pending = bundle.items.filter { itemStates[$0.id] != .saved }
        save(pending.isEmpty ? bundle.items : pending)
    }

    func save(_ item: MediaItem) {
        guard itemStates[item.id] != .saved else { return }
        save([item])
    }

    private func save(_ items: [MediaItem]) {
        guard let bundle, !items.isEmpty, phase != .saving else { return }
        errorMessage = nil
        withAnimation(.snappy) { phase = .saving }
        for item in items { itemStates[item.id] = .downloading(0) }
        liveActivity.start(title: bundle.title, platform: bundle.platform, total: items.count)
        beginBackgroundTask()

        saveTask = Task {
            do {
                let result = try await SavePipeline.save(
                    items, from: bundle,
                    onItemSaved: { [weak self] id in
                        Task { @MainActor in
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { self?.itemStates[id] = .saved }
                        }
                    },
                    onItemFailed: { [weak self] id, error in
                        Task { @MainActor in self?.itemStates[id] = .failed(error.localizedDescription) }
                    },
                    progress: { [weak self] p in
                        Task { @MainActor in self?.apply(p) }
                    })
                let message = result.failures.isEmpty
                    ? (result.savedItemIDs.count == 1 ? "Saved to Photos" : "Saved \(result.savedItemIDs.count) items")
                    : "Saved \(result.savedItemIDs.count) of \(items.count)"
                liveActivity.finish(success: true, message: message, total: items.count)
                withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) { phase = .done }
                successTick += 1
                if !result.failures.isEmpty {
                    errorMessage = "\(result.failures.count) item\(result.failures.count == 1 ? "" : "s") couldn't be saved. Tap them to retry."
                }
            } catch is CancellationError {
                liveActivity.finish(success: false, message: "Cancelled", total: items.count)
                withAnimation { phase = .ready }
                for item in items where itemStates[item.id] != .saved { itemStates[item.id] = .waiting }
            } catch {
                liveActivity.finish(success: false, message: "Couldn't save", total: items.count)
                for item in items where itemStates[item.id] != .saved { itemStates[item.id] = .waiting }
                fail(error, keepBundle: true)
            }
            endBackgroundTask()
        }
    }

    func cancelSave() {
        saveTask?.cancel()
    }

    func reset() {
        fetchTask?.cancel()
        saveTask?.cancel()
        withAnimation(.snappy) {
            linkText = ""
            bundle = nil
            itemStates = [:]
            progress = nil
            errorMessage = nil
            lastError = nil
            phase = .idle
        }
    }

    // MARK: - Clipboard

    func checkClipboard() {
        UIPasteboard.general.detectPatterns(for: [\.probableWebURL]) { [weak self] result in
            let hasURL = (try? result.get())?.contains(\.probableWebURL) ?? false
            Task { @MainActor in self?.clipboardHasLink = hasURL }
        }
    }

    // MARK: - Helpers

    private func apply(_ p: SaveProgress) {
        progress = p
        if let id = p.currentItemID, itemStates[id] != .saved {
            itemStates[id] = .downloading(p.itemFraction)
        }
        liveActivity.update(p)
    }

    private func fail(_ error: Error, keepBundle: Bool = false) {
        let mapped = KeepsakeError.from(error)
        withAnimation(.snappy) {
            errorMessage = mapped.localizedDescription
            lastError = mapped as? KeepsakeError
            if keepBundle, bundle != nil {
                phase = .ready
            } else {
                bundle = nil
                phase = .failed
            }
        }
        errorTick += 1
    }

    private func beginBackgroundTask() {
        endBackgroundTask()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Keepsake save") { [weak self] in
            Task { @MainActor in self?.endBackgroundTask() }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
