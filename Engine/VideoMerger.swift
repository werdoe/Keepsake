import AVFoundation
import Foundation

/// Combines a video-only stream and an audio-only stream into one MP4 without re-encoding.
enum VideoMerger {
    static func merge(video: URL, audio: URL) async throws -> URL {
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: video)
        let audioAsset = AVURLAsset(url: audio)

        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first else {
            throw KeepsakeError.downloadFailed
        }
        let videoDuration = try await videoAsset.load(.duration)
        let range = CMTimeRange(start: .zero, duration: videoDuration)

        guard let compositionVideo = composition.addMutableTrack(withMediaType: .video,
                                                                 preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw KeepsakeError.downloadFailed
        }
        try compositionVideo.insertTimeRange(range, of: videoTrack, at: .zero)
        compositionVideo.preferredTransform = try await videoTrack.load(.preferredTransform)

        if let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first {
            let audioDuration = try await audioAsset.load(.duration)
            let audioRange = CMTimeRange(start: .zero, duration: CMTimeMinimum(videoDuration, audioDuration))
            if let compositionAudio = composition.addMutableTrack(withMediaType: .audio,
                                                                  preferredTrackID: kCMPersistentTrackID_Invalid) {
                try compositionAudio.insertTimeRange(audioRange, of: audioTrack, at: .zero)
            }
        }

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw KeepsakeError.downloadFailed
        }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        export.outputURL = output
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        await export.export()

        guard export.status == .completed else {
            throw export.error ?? KeepsakeError.downloadFailed
        }
        return output
    }
}
