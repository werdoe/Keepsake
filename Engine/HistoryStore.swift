import Foundation
import UIKit

/// One saved link, shown in the Library.
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

    var itemCount: Int { photoCount + videoCount }

    var thumbnailURL: URL? {
        thumbnailFile.map { HistoryStore.thumbnailsDirectory.appendingPathComponent($0) }
    }
}

/// Download history, stored as JSON in the shared app group so share-sheet saves appear too.
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published private(set) var entries: [HistoryEntry] = []

    private let fileURL = AppGroup.dataDirectory.appendingPathComponent("history.json")
    static var thumbnailsDirectory: URL {
        let dir = AppGroup.dataDirectory.appendingPathComponent("Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private init() { reload() }

    /// Re-reads from disk (the share extension may have added entries).
    func reload() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return }
        let sorted = decoded.sorted { $0.date > $1.date }
        if Thread.isMainThread {
            entries = sorted
        } else {
            DispatchQueue.main.async { self.entries = sorted }
        }
    }

    func add(_ entry: HistoryEntry) {
        var all = readFromDisk()
        all.insert(entry, at: 0)
        if all.count > 500 { all = Array(all.prefix(500)) }
        write(all)
    }

    func remove(_ entry: HistoryEntry) {
        if let file = entry.thumbnailURL { try? FileManager.default.removeItem(at: file) }
        write(readFromDisk().filter { $0.id != entry.id })
    }

    func clear() {
        try? FileManager.default.removeItem(at: Self.thumbnailsDirectory)
        write([])
    }

    /// Stores a small JPEG preview for the Library grid.
    static func storeThumbnail(from url: URL) async -> String? {
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let image = UIImage(data: data) else { return nil }
        let maxSide: CGFloat = 480
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        let small = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let jpeg = small.jpegData(compressionQuality: 0.8) else { return nil }
        let name = UUID().uuidString + ".jpg"
        do {
            try jpeg.write(to: thumbnailsDirectory.appendingPathComponent(name))
            return name
        } catch {
            return nil
        }
    }

    private func readFromDisk() -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([HistoryEntry].self, from: data)) ?? []
    }

    private func write(_ all: [HistoryEntry]) {
        if let data = try? JSONEncoder().encode(all) {
            try? data.write(to: fileURL, options: .atomic)
        }
        reload()
        if all.isEmpty {
            if Thread.isMainThread { entries = [] } else { DispatchQueue.main.async { self.entries = [] } }
        }
    }
}
