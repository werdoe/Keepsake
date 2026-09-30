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
        case .saving: return "Saving"
        case .done: return total == 1 ? "Saved" : "Saved \(total) items"
        }
    }
}

struct SaveResult {
    var savedItemIDs: [UUID]
    var failures: [(UUID, Error)]
    var historyEntry: HistoryEntry?
}

/// Downloads each item (in the chosen quality), merges DASH streams, adds captions and dates,
/// saves to Photos and/or Files, and records history.
enum SavePipeline {
    static func save(
        _ items: [MediaItem],
        from bundle: MediaBundle,
        settings: AppSettings = .shared,
        downloader: MediaDownloading,
        onItemSaved: ((UUID) -> Void)? = nil,
        onItemFailed: ((UUID, Error) -> Void)? = nil,
        progress: @escaping (SaveProgress) -> Void
    ) async throws -> SaveResult {
        let destination = settings.destination
        let canUseAlbum = destination.includesPhotos ? try await MediaSaver.prepare(wantsAlbum: settings.saveToAlbum) : false
        let albumTarget: MediaSaver.AlbumTarget? = canUseAlbum
            ? (settings.albumPerAccount ? .account(bundle.title) : .keepsake)
            : nil
        var filePaths: [String] = []
        let total = items.count
        var saved: [UUID] = []
        var failures: [(UUID, Error)] = []
        var assetIDs: [String] = []
        var bestLabel: String?

        for (index, item) in items.enumerated() {
            try Task.checkCancellation()
            let report: (SaveProgress.Phase, Double) -> Void = { phase, itemFraction in
                let overall = (Double(index) + itemFraction) / Double(max(total, 1))
                progress(SaveProgress(completed: index, total: total, fraction: overall, phase: phase,
                                      currentItemID: item.id, itemFraction: itemFraction))
            }
            do {
                var (file, label) = try await downloadFile(for: item, quality: settings.quality, wifiOnly: settings.wifiOnly,
                                                           downloader: downloader, report: report)
                if bestLabel == nil { bestLabel = label }
                report(.saving, 0.96)

                if item.kind == .photo {
                    file = try MediaSaver.normalisedPhoto(file)
                    if settings.embedCaption {
                        file = MetadataWriter.embed(into: file, caption: bundle.caption, source: bundle.sourceURL, date: bundle.date)
                    }
                }
                if destination.includesFiles {
                    filePaths.append(try FileStore.save(file, kind: item.kind, platform: bundle.platform, title: bundle.title,
                                           index: index, date: bundle.date ?? Date()))
                }
                if destination.includesPhotos,
                   let id = try await MediaSaver.save(file: file, kind: item.kind, album: albumTarget,
                                                      creationDate: settings.keepOriginalDate ? bundle.date : nil) {
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
            let first = savedItems.first ?? bundle.items[0]
            let thumb = await HistoryStore.storeThumbnail(from: first.thumbnailURL, headers: first.standard.headers)
            let newEntry = HistoryEntry(
                date: Date(), platform: bundle.platform, title: bundle.title, caption: bundle.caption,
                sourceURL: bundle.sourceURL,
                photoCount: savedItems.filter { $0.kind == .photo }.count,
                videoCount: savedItems.filter { $0.kind == .video }.count,
                thumbnailFile: thumb, assetIdentifiers: assetIDs, qualityLabel: bestLabel, sourceKey: bundle.key,
                filePaths: filePaths.isEmpty ? nil : filePaths)
            HistoryStore.shared.add(newEntry)
            entry = newEntry
        }
        return SaveResult(savedItemIDs: saved, failures: failures, historyEntry: entry)
    }

    /// Returns a local file ready to save, plus a resolution label ("1080p") when known.
    private static func downloadFile(
        for item: MediaItem,
        quality: QualityPreference,
        wifiOnly: Bool,
        downloader: MediaDownloading,
        report: @escaping (SaveProgress.Phase, Double) -> Void
    ) async throws -> (URL, String?) {
        let source = item.source(for: quality)
        let ext = item.kind == .video ? "mp4" : "jpg"

        if let audioURL = source.audioURL {
            do {
                // Video is usually most of the bytes; weight progress accordingly.
                let video = try await downloader.download(source, url: source.url, fileExtension: "mp4", wifiOnly: wifiOnly) {
                    report(.downloading, $0 * 0.8)
                }
                let audio = try await downloader.download(source, url: audioURL, fileExtension: "m4a", wifiOnly: wifiOnly) {
                    report(.downloading, 0.8 + $0 * 0.1)
                }
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
        do {
            let file = try await downloader.download(fallback, url: fallback.url, fileExtension: ext, wifiOnly: wifiOnly) {
                report(.downloading, $0 * 0.95)
            }
            return (file, fallback.resolutionLabel)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error where fallback != item.standard {
            // e.g. a higher-quality TikTok file that refused to download: use the default one.
            let mapped = KeepsakeError.from(error)
            if KeepsakeError.stopsBatch(mapped) { throw mapped }
            let file = try await downloader.download(item.standard, url: item.standard.url, fileExtension: ext, wifiOnly: wifiOnly) {
                report(.downloading, $0 * 0.95)
            }
            return (file, item.standard.resolutionLabel)
        }
    }
}
