import Foundation

/// Progress reported while saving a bundle.
struct SaveProgress {
    enum Phase { case downloading, merging, saving, done }

    var completed: Int
    var total: Int
    /// Progress of the whole job, 0...1.
    var fraction: Double
    var phase: Phase
    var currentItemID: UUID?
    var itemFraction: Double

    var message: String {
        switch phase {
        case .downloading: return total > 1 ? "Downloading \(min(completed + 1, total)) of \(total)" : "Downloading"
        case .merging: return "Combining video and audio"
        case .saving: return "Saving to Photos"
        case .done: return total == 1 ? "Saved to Photos" : "Saved \(total) items"
        }
    }
}

struct SaveResult {
    var savedItemIDs: [UUID]
    var failures: [(UUID, Error)]
    var historyEntry: HistoryEntry?
}

/// Downloads each item (in the chosen quality), merges DASH streams, saves to Photos and records history.
enum SavePipeline {
    static func save(
        _ items: [MediaItem],
        from bundle: MediaBundle,
        settings: AppSettings = .shared,
        onItemSaved: ((UUID) -> Void)? = nil,
        onItemFailed: ((UUID, Error) -> Void)? = nil,
        progress: @escaping (SaveProgress) -> Void
    ) async throws -> SaveResult {
        let useAlbum = try await MediaSaver.prepare(wantsAlbum: settings.saveToAlbum)
        let downloader = Downloader(wifiOnly: settings.wifiOnly)
        let total = items.count
        var saved: [UUID] = []
        var failures: [(UUID, Error)] = []
        var assetIDs: [String] = []
        var bestLabel: String?

        for (index, item) in items.enumerated() {
            try Task.checkCancellation()
            func report(_ phase: SaveProgress.Phase, _ itemFraction: Double) {
                let overall = (Double(index) + itemFraction) / Double(max(total, 1))
                progress(SaveProgress(completed: index, total: total, fraction: overall, phase: phase,
                                      currentItemID: item.id, itemFraction: itemFraction))
            }
            do {
                let (file, label) = try await downloadFile(for: item, quality: settings.quality, downloader: downloader) { phase, fraction in
                    report(phase, fraction)
                }
                if bestLabel == nil { bestLabel = label }
                report(.saving, 0.97)
                if let id = try await MediaSaver.save(file: file, kind: item.kind, intoAlbum: useAlbum) {
                    assetIDs.append(id)
                }
                try? FileManager.default.removeItem(at: file)
                saved.append(item.id)
                onItemSaved?(item.id)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let mapped = KeepsakeError.from(error)
                failures.append((item.id, mapped))
                onItemFailed?(item.id, mapped)
                // Wi-Fi-only, offline and permission problems affect every item, so stop early.
                if KeepsakeError.stopsBatch(mapped) { throw mapped }
            }
        }

        if saved.isEmpty, let first = failures.first { throw first.1 }

        progress(SaveProgress(completed: total, total: total, fraction: 1, phase: .done, currentItemID: nil, itemFraction: 1))

        var entry: HistoryEntry?
        if settings.keepHistory {
            let savedItems = items.filter { saved.contains($0.id) }
            let thumb = await HistoryStore.storeThumbnail(from: savedItems.first?.thumbnailURL ?? bundle.items[0].thumbnailURL)
            let newEntry = HistoryEntry(
                date: Date(), platform: bundle.platform, title: bundle.title, caption: bundle.caption,
                sourceURL: bundle.sourceURL,
                photoCount: savedItems.filter { $0.kind == .photo }.count,
                videoCount: savedItems.filter { $0.kind == .video }.count,
                thumbnailFile: thumb, assetIdentifiers: assetIDs, qualityLabel: bestLabel)
            HistoryStore.shared.add(newEntry)
            entry = newEntry
        }
        return SaveResult(savedItemIDs: saved, failures: failures, historyEntry: entry)
    }

    /// Returns a local file ready for Photos, plus a resolution label ("1080p") when known.
    private static func downloadFile(
        for item: MediaItem,
        quality: QualityPreference,
        downloader: Downloader,
        report: @escaping (SaveProgress.Phase, Double) -> Void
    ) async throws -> (URL, String?) {
        let source = item.source(for: quality)
        let ext = item.kind == .video ? "mp4" : "jpg"

        if let audioURL = source.audioURL {
            do {
                // Video is usually most of the bytes; weight progress accordingly.
                let video = try await downloader.download(source.url, fileExtension: "mp4") { report(.downloading, $0 * 0.8) }
                let audio = try await downloader.download(audioURL, fileExtension: "m4a") { report(.downloading, 0.8 + $0 * 0.1) }
                report(.merging, 0.92)
                defer {
                    try? FileManager.default.removeItem(at: video)
                    try? FileManager.default.removeItem(at: audio)
                }
                let merged = try await VideoMerger.merge(video: video, audio: audio)
                return (merged, source.resolutionLabel)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Fall back to the always-playable version if the high-quality path fails.
                let mapped = KeepsakeError.from(error)
                if KeepsakeError.stopsBatch(mapped) { throw mapped }
            }
        }
        let fallback = source.audioURL == nil ? source : item.standard
        let file = try await downloader.download(fallback.url, fileExtension: ext) { report(.downloading, $0 * 0.95) }
        return (file, fallback.resolutionLabel)
    }
}
