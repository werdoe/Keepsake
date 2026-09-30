import Foundation

/// A named group of saves you put together yourself ("Reminders", "Recipes").
struct SaveCollection: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var symbol: String
    var entryIDs: [UUID]
    var created: Date = Date()
}

/// Your own collections, stored in the shared app group.
final class CollectionsStore: ObservableObject {
    static let shared = CollectionsStore()

    @Published private(set) var collections: [SaveCollection] = []

    static let symbols = ["star.fill", "heart.fill", "book.fill", "moon.stars.fill", "fork.knife", "graduationcap.fill",
                          "sparkles", "leaf.fill", "music.note", "camera.fill", "lightbulb.fill", "bookmark.fill"]

    private var fileURL: URL { AppGroup.dataDirectory.appendingPathComponent("collections.json") }

    private init() { reload() }

    func reload() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([SaveCollection].self, from: data) else { return }
        collections = decoded
    }

    @discardableResult
    func create(name: String, symbol: String, entryIDs: [UUID] = []) -> SaveCollection {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let collection = SaveCollection(name: trimmed.isEmpty ? "New Collection" : trimmed, symbol: symbol, entryIDs: entryIDs)
        collections.insert(collection, at: 0)
        save()
        return collection
    }

    func add(_ ids: [UUID], to collection: SaveCollection) {
        guard let index = collections.firstIndex(where: { $0.id == collection.id }) else { return }
        for id in ids where !collections[index].entryIDs.contains(id) {
            collections[index].entryIDs.insert(id, at: 0)
        }
        save()
    }

    func remove(_ ids: [UUID], from collection: SaveCollection) {
        guard let index = collections.firstIndex(where: { $0.id == collection.id }) else { return }
        collections[index].entryIDs.removeAll { ids.contains($0) }
        save()
    }

    func rename(_ collection: SaveCollection, to name: String, symbol: String) {
        guard let index = collections.firstIndex(where: { $0.id == collection.id }) else { return }
        collections[index].name = name
        collections[index].symbol = symbol
        save()
    }

    func delete(_ collection: SaveCollection) {
        collections.removeAll { $0.id == collection.id }
        save()
    }

    /// Drops references to saves that no longer exist.
    func prune(existing: Set<UUID>) {
        var changed = false
        for index in collections.indices {
            let before = collections[index].entryIDs.count
            collections[index].entryIDs.removeAll { !existing.contains($0) }
            changed = changed || before != collections[index].entryIDs.count
        }
        if changed { save() }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(collections) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
