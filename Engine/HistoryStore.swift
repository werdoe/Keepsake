import Foundation
import UIKit
import WidgetKit

/// One saved link, shown in the Library and the widgets.
struct HistoryEntry: Identifiable, Codable, Hashable {
    var id = UUID()
    var date: Date
    var platform: Platform
    var title: String
    var caption: String?
    var sourceURL: URL
    var photoCount: Int
    var videoCount: Int
    var thumbnailFile: String?
    var assetIdentifiers: [String]
    var qualityLabel: String?
    /// Identity of the post, for "you already saved this".
    var sourceKey: String?
    /// Copies saved to Files, relative to the app's Documents folder.
    var filePaths: [String]?
    var isFavorite: Bool?

    var itemCount: Int { photoCount + videoCount }
    var favorite: Bool { isFavorite ?? false }

    /// The account this came from ("@user"), used to group the Library into folders.
    var account: String { title }

    var fileURLs: [URL] {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return (filePaths ?? []).map { documents.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    var thumbnailURL: URL? {
        thumbnailFile.map { HistoryStore.thumbnailsDirectory.appendingPathComponent($0) }
    }
}

/// Download history, stored as JSON in the shared app group so share-sheet saves and widgets see it.
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published private(set) var entries: [HistoryEntry] = []

    private static var fileURL: URL { AppGroup.dataDirectory.appendingPathComponent("history.json") }
    static var thumbnailsDirectory: URL {
        let dir = AppGroup.dataDirectory.appendingPathComponent("Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private init() {
        Self.migrateStrandedData()
        reload()
    }

    /// Before the app-group fix, the share sheet could end up writing to its own private folder
    /// (SideStore renamed the group). Once the shared group works, move that data into it.
    static func migrateStrandedData() {
        guard AppGroup.isAvailable else { return }
        let fm = FileManager.default
        let privateDir = AppGroup.privateDirectory
        let shared = AppGroup.dataDirectory
        guard privateDir.standardizedFileURL != shared.standardizedFileURL else { return }

        // Library entries and their thumbnails.
        let strandedHistory = privateDir.appendingPathComponent("history.json")
        if let data = try? Data(contentsOf: strandedHistory),
           let stranded = try? JSONDecoder().decode([HistoryEntry].self, from: data), !stranded.isEmpty {
            let privateThumbs = privateDir.appendingPathComponent("Thumbnails", isDirectory: true)
            for name in stranded.compactMap(\.thumbnailFile) {
                let target = thumbnailsDirectory.appendingPathComponent(name)
                if !fm.fileExists(atPath: target.path) {
                    try? fm.moveItem(at: privateThumbs.appendingPathComponent(name), to: target)
                }
            }
            var all = readEntries()
            let existing = Set(all.map(\.id))
            all += stranded.filter { !existing.contains($0.id) }
            if let merged = try? JSONEncoder().encode(all.sorted { $0.date > $1.date }) {
                try? merged.write(to: fileURL, options: .atomic)
            }
            try? fm.removeItem(at: strandedHistory)
        }

        // Queued links.
        let strandedQueue = privateDir.appendingPathComponent("queue.json")
        if let data = try? Data(contentsOf: strandedQueue),
           let items = try? JSONDecoder().decode([QueuedLink].self, from: data) {
            for item in items { OfflineQueue.shared.add(item.link) }
            try? fm.removeItem(at: strandedQueue)
        }

        // Files the share sheet saved for the Files app.
        let strandedInbox = privateDir.appendingPathComponent("FilesInbox", isDirectory: true)
        if fm.fileExists(atPath: strandedInbox.path) {
            let sharedInbox = shared.appendingPathComponent("FilesInbox", isDirectory: true)
            try? fm.createDirectory(at: sharedInbox, withIntermediateDirectories: true)
            for item in (try? fm.contentsOfDirectory(at: strandedInbox, includingPropertiesForKeys: nil)) ?? [] {
                try? fm.moveItem(at: item, to: sharedInbox.appendingPathComponent(item.lastPathComponent))
            }
        }
    }

    /// Reads entries straight from disk (used by widgets, which don't keep a store around).
    static func readEntries() -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return [] }
        return decoded.sorted { $0.date > $1.date }
    }

    /// Re-reads from disk (the share extension may have added entries).
    func reload() {
        let sorted = Self.readEntries()
        if Thread.isMainThread {
            entries = sorted
        } else {
            DispatchQueue.main.async { self.entries = sorted }
        }
    }

    /// The most recent save of the same post, if any.
    func previousSave(of key: String?) -> HistoryEntry? {
        guard let key else { return nil }
        return Self.readEntries().first { $0.sourceKey == key }
    }

    func add(_ entry: HistoryEntry) {
        var all = Self.readEntries()
        all.insert(entry, at: 0)
        if all.count > 1000 { all = Array(all.prefix(1000)) }
        write(all)
    }

    func toggleFavorite(_ entry: HistoryEntry) {
        var all = Self.readEntries()
        guard let index = all.firstIndex(where: { $0.id == entry.id }) else { return }
        all[index].isFavorite = !(all[index].isFavorite ?? false)
        write(all)
    }

    func remove(_ entry: HistoryEntry) {
        if let file = entry.thumbnailURL { try? FileManager.default.removeItem(at: file) }
        write(Self.readEntries().filter { $0.id != entry.id })
    }

    func clear() {
        try? FileManager.default.removeItem(at: Self.thumbnailsDirectory)
        write([])
    }

    // MARK: - Backup (a single file you can keep in iCloud Drive or send to another phone)

    private struct Backup: Codable {
        var version = 1
        var exported: Date
        var entries: [HistoryEntry]
        var thumbnails: [String: Data]
    }

    func exportBackup() throws -> URL {
        let all = Self.readEntries()
        var thumbnails: [String: Data] = [:]
        for entry in all {
            if let name = entry.thumbnailFile, let url = entry.thumbnailURL, let data = try? Data(contentsOf: url) {
                thumbnails[name] = data
            }
        }
        let backup = Backup(exported: Date(), entries: all, thumbnails: thumbnails)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Keepsake Library \(formatter.string(from: Date()))")
            .appendingPathExtension("json")
        try JSONEncoder().encode(backup).write(to: url, options: .atomic)
        return url
    }

    /// Merges a backup into the Library. Returns how many entries were added.
    @discardableResult
    func importBackup(from url: URL) throws -> Int {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let backup = try JSONDecoder().decode(Backup.self, from: Data(contentsOf: url))
        var all = Self.readEntries()
        let existing = Set(all.map(\.id))
        var added = 0
        for entry in backup.entries where !existing.contains(entry.id) {
            if let name = entry.thumbnailFile, let data = backup.thumbnails[name] {
                try? data.write(to: Self.thumbnailsDirectory.appendingPathComponent(name))
            }
            all.append(entry)
            added += 1
        }
        write(all.sorted { $0.date > $1.date })
        return added
    }

    // MARK: - Thumbnails

    /// Stores a small JPEG preview for the Library grid and widgets.
    static func storeThumbnail(from url: URL, headers: [String: String]?) async -> String? {
        var request = URLRequest(url: url)
        for (name, value) in headers ?? [:] { request.setValue(value, forHTTPHeaderField: name) }
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let image = UIImage(data: data) else { return nil }
        let maxSide: CGFloat = 480
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let small = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let jpeg = small.jpegData(compressionQuality: 0.8) else { return nil }
        let name = UUID().uuidString + ".jpg"
        do {
            try jpeg.write(to: thumbnailsDirectory.appendingPathComponent(name))
            return name
        } catch {
            return nil
        }
    }

    private func write(_ all: [HistoryEntry]) {
        if let data = try? JSONEncoder().encode(all) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
        reload()
        WidgetCenter.shared.reloadAllTimelines()
    }
}
