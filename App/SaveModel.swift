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
    /// Set when the fetched post was saved before.
    @Published private(set) var previousSave: HistoryEntry?
    /// Short confirmation shown at the bottom ("Caption copied").
    @Published private(set) var toast: String?
    @Published private(set) var audioProgress: [UUID: Double] = [:]
    /// Incremented to trigger haptics.
    @Published private(set) var successTick = 0
    @Published private(set) var errorTick = 0
    @Published private(set) var lightTick = 0

    private var fetchTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private let liveActivity = LiveActivityController()
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    static let pendingPasteKey = "pendingPasteSave"

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
            previousSave = nil
        }
        let text = linkText
        fetchTask = Task {
            do {
                let result = try await MediaFetcher.fetch(text)
                guard !Task.isCancelled else { return }
                let earlier = HistoryStore.shared.previousSave(of: result.key)
                withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
                    bundle = result
                    previousSave = earlier
                    itemStates = Dictionary(uniqueKeysWithValues: result.items.map { ($0.id, ItemState.waiting) })
                    phase = .ready
                }
                // Don't silently save a duplicate; the banner lets you choose.
                if autoSave && earlier == nil { saveAll() }
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
        withAnimation(.snappy) {
            phase = .saving
            previousSave = nil
        }
        for item in items { itemStates[item.id] = .downloading(0) }
        liveActivity.start(title: bundle.title, platform: bundle.platform, total: items.count)
        beginBackgroundTask()

        saveTask = Task {
            do {
                let result = try await SavePipeline.save(
                    items, from: bundle, downloader: BackgroundDownloader.shared,
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
                let place = AppSettings.shared.destination == .files ? "Files" : "Photos"
                let message = result.failures.isEmpty
                    ? (result.savedItemIDs.count == 1 ? "Saved to \(place)" : "Saved \(result.savedItemIDs.count) items")
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
            previousSave = nil
            phase = .idle
        }
    }

    // MARK: - Audio

    func saveAudio(_ item: MediaItem) {
        guard let bundle, audioProgress[item.id] == nil else { return }
        audioProgress[item.id] = 0
        Task {
            do {
                _ = try await AudioSaver.saveAudio(of: item, from: bundle, downloader: BackgroundDownloader.shared,
                                                   wifiOnly: AppSettings.shared.wifiOnly) { [weak self] p in
                    Task { @MainActor in self?.audioProgress[item.id] = p }
                }
                audioProgress[item.id] = nil
                successTick += 1
                show("Audio saved to Files › Keepsake › Audio")
            } catch {
                audioProgress[item.id] = nil
                errorTick += 1
                show(KeepsakeError.from(error).localizedDescription)
            }
        }
    }

    // MARK: - Clipboard

    func copy(_ text: String, confirmation: String) {
        UIPasteboard.general.string = text
        lightTick += 1
        show(confirmation)
    }

    func checkClipboard() {
        UIPasteboard.general.detectPatterns(for: [\.probableWebURL]) { [weak self] result in
            let hasURL = (try? result.get())?.contains(\.probableWebURL) ?? false
            Task { @MainActor in self?.clipboardHasLink = hasURL }
        }
    }

    /// The widget / Control Center "Paste & Save" button opens the app and leaves a note;
    /// pick up the clipboard link and save it.
    func handlePendingPasteSave() {
        let defaults = AppGroup.defaults
        guard let requested = defaults.object(forKey: Self.pendingPasteKey) as? Date else { return }
        defaults.removeObject(forKey: Self.pendingPasteKey)
        guard Date().timeIntervalSince(requested) < 120 else { return }
        if let text = UIPasteboard.general.string, MediaLink.parse(text) != nil {
            paste(text, autoSave: true)
        } else {
            show("No supported link on your clipboard. Copy one first.")
            errorTick += 1
        }
    }

    // MARK: - Helpers

    func show(_ message: String) {
        toastTask?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { toast = message }
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { toast = nil }
        }
    }

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
