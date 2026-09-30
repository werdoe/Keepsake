import Foundation

/// Links waiting to be saved because there was no connection (or no Wi-Fi with "Wi-Fi only" on).
/// Stored in the shared app group, so the share sheet can queue links too.
/// The app works through the queue as soon as a suitable connection is back.
struct QueuedLink: Identifiable, Codable, Hashable {
    var id = UUID()
    var link: String
    var added: Date = Date()
    var attempts: Int = 0
    var lastError: String?

    var platform: Platform? { MediaLink.parse(link)?.platform }
}

final class OfflineQueue: ObservableObject {
    static let shared = OfflineQueue()

    @Published private(set) var items: [QueuedLink] = []

    private var fileURL: URL { AppGroup.dataDirectory.appendingPathComponent("queue.json") }

    private init() { reload() }

    func reload() {
        let loaded = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([QueuedLink].self, from: $0) } ?? []
        if Thread.isMainThread { items = loaded } else { DispatchQueue.main.async { self.items = loaded } }
    }

    /// Adds a link unless it's already waiting.
    func add(_ link: String) {
        var all = readFromDisk()
        guard !all.contains(where: { $0.link == link }) else { return }
        all.append(QueuedLink(link: link))
        write(all)
    }

    func remove(_ item: QueuedLink) {
        write(readFromDisk().filter { $0.id != item.id })
    }

    func markFailed(_ item: QueuedLink, error: String) {
        var all = readFromDisk()
        guard let index = all.firstIndex(where: { $0.id == item.id }) else { return }
        all[index].attempts += 1
        all[index].lastError = error
        write(all)
    }

    func clear() { write([]) }

    private func readFromDisk() -> [QueuedLink] {
        (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([QueuedLink].self, from: $0) } ?? []
    }

    private func write(_ all: [QueuedLink]) {
        if let data = try? JSONEncoder().encode(all) { try? data.write(to: fileURL, options: .atomic) }
        reload()
    }

    /// Errors that mean "try again later with a connection" rather than "this link won't work".
    static func isConnectionProblem(_ error: Error) -> Bool {
        guard let e = error as? KeepsakeError else {
            if let urlError = error as? URLError {
                return [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .timedOut].contains(urlError.code)
            }
            return false
        }
        return e == .offline || e == .wifiOnly
    }
}
