import AVFoundation
import Foundation

/// "Save Audio": keeps just the sound of a video (or a TikTok sound) as an .m4a in Files.
enum AudioSaver {
    static func saveAudio(of item: MediaItem, from bundle: MediaBundle, downloader: MediaDownloading,
                          wifiOnly: Bool, progress: @escaping (Double) -> Void) async throws -> URL {
        let local: URL
        if let direct = item.directAudio {
            // A ready-made audio stream: download it and wrap it as .m4a.
            let file = try await downloader.download(direct, url: direct.url, fileExtension: "m4a", wifiOnly: wifiOnly) {
                progress($0 * 0.9)
            }
            local = try await exportAudio(from: file)
            try? FileManager.default.removeItem(at: file)
        } else {
            // Download the video and pull out its audio track.
            let file = try await downloader.download(item.standard, url: item.standard.url, fileExtension: "mp4", wifiOnly: wifiOnly) {
                progress($0 * 0.9)
            }
            local = try await exportAudio(from: file)
            try? FileManager.default.removeItem(at: file)
        }
        progress(1)
        let saved = try FileStore.saveAudio(local, title: bundle.title + " audio", date: Date())
        try? FileManager.default.removeItem(at: local)
        return saved
    }

    /// Re-wraps (without re-encoding when possible) the audio track as .m4a.
    private static func exportAudio(from file: URL) async throws -> URL {
        let asset = AVURLAsset(url: file)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else {
            throw KeepsakeError.server("This video has no sound to save.")
        }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw KeepsakeError.downloadFailed
        }
        export.outputURL = output
        export.outputFileType = .m4a
        await export.export()
        guard export.status == .completed else { throw export.error ?? KeepsakeError.downloadFailed }
        return output
    }
}
