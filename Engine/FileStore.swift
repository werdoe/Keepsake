import Foundation

/// Saves copies into the Files app (On My iPhone › Keepsake).
///
/// Only the app's own Documents folder appears in Files, so the share extension drops files
/// into an inbox in the shared container and the app moves them over the next time it opens.
enum FileStore {
    private static let inboxName = "FilesInbox"

    /// Where finished files should go from the current process.
    private static var root: URL {
        if Bundle.main.bundlePath.hasSuffix(".appex") {
            return AppGroup.dataDirectory.appendingPathComponent(inboxName, isDirectory: true)
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Saves into Keepsake › Platform › Account and returns the path relative to Documents.
    static func save(_ file: URL, kind: MediaItem.Kind, platform: Platform, title: String, index: Int, date: Date) throws -> String {
        let folder = root.appendingPathComponent(platform.name, isDirectory: true)
            .appendingPathComponent(folderName(title), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = file.pathExtension.isEmpty ? (kind == .video ? "mp4" : "jpg") : file.pathExtension
        let destination = uniqueURL(in: folder, base: fileName(title: title, index: index, date: date), ext: ext)
        try FileManager.default.copyItem(at: file, to: destination)
        return destination.path.replacingOccurrences(of: root.path + "/", with: "")
    }

    private static func folderName(_ title: String) -> String {
        let cleaned = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Other" : String(cleaned.prefix(60))
    }

    /// Saves an audio file into Files › Keepsake › Audio.
    static func saveAudio(_ file: URL, title: String, date: Date) throws -> URL {
        let folder = root.appendingPathComponent("Audio", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = uniqueURL(in: folder, base: fileName(title: title, index: 0, date: date),
                                    ext: file.pathExtension.isEmpty ? "m4a" : file.pathExtension)
        try FileManager.default.copyItem(at: file, to: destination)
        return destination
    }

    /// Called by the app: moves files the share extension saved into the visible Documents folder.
    static func collectInbox() {
        let inbox = AppGroup.dataDirectory.appendingPathComponent(inboxName, isDirectory: true)
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let enumerator = FileManager.default.enumerator(at: inbox, includingPropertiesForKeys: [.isRegularFileKey]) else { return }
        for case let file as URL in enumerator {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let relative = file.path.replacingOccurrences(of: inbox.path + "/", with: "")
            let target = documents.appendingPathComponent(relative)
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let destination = uniqueURL(in: target.deletingLastPathComponent(),
                                        base: target.deletingPathExtension().lastPathComponent, ext: target.pathExtension)
            try? FileManager.default.moveItem(at: file, to: destination)
        }
    }

    private static func fileName(title: String, index: Int, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = String(title.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let base = cleaned.isEmpty ? "Keepsake" : String(cleaned.prefix(40))
        return "\(base)_\(formatter.string(from: date))_\(index + 1)"
    }

    private static func uniqueURL(in folder: URL, base: String, ext: String) -> URL {
        var candidate = folder.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base)-\(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }
}
