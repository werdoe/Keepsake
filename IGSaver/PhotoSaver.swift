import Foundation
import Photos
import UIKit

enum SaveError: LocalizedError {
    case noPermission
    case downloadFailed

    var errorDescription: String? {
        switch self {
        case .noPermission:
            return "IGSaver isn't allowed to add to your Photos. Turn it on in Settings › IGSaver › Photos."
        case .downloadFailed:
            return "The download didn't finish. Check your connection and try again."
        }
    }
}

/// Downloads media and adds it to the Photos library.
enum PhotoSaver {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }()

    static func ensurePermission() async throws {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        let status = current == .notDetermined
            ? await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            : current
        guard status == .authorized || status == .limited else { throw SaveError.noPermission }
    }

    static func save(_ item: MediaItem) async throws {
        try await ensurePermission()
        var request = URLRequest(url: item.url)
        request.setValue(InstagramClient.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.instagram.com/", forHTTPHeaderField: "Referer")

        switch item.kind {
        case .photo:
            let (data, response) = try await session.data(for: request)
            guard ((response as? HTTPURLResponse)?.statusCode ?? 200) < 400, !data.isEmpty else {
                throw SaveError.downloadFailed
            }
            // Photos handles JPEG/HEIC/PNG natively; anything else (e.g. WebP) is converted to JPEG.
            let mime = response.mimeType ?? ""
            let photoData: Data
            if ["image/jpeg", "image/jpg", "image/heic", "image/png"].contains(mime) {
                photoData = data
            } else if let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.95) {
                photoData = jpeg
            } else {
                photoData = data
            }
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: photoData, options: nil)
            }

        case .video:
            let (tempURL, response) = try await session.download(for: request)
            guard ((response as? HTTPURLResponse)?.statusCode ?? 200) < 400 else {
                throw SaveError.downloadFailed
            }
            // Photos needs a proper file extension to recognise the video.
            let fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mp4")
            try FileManager.default.moveItem(at: tempURL, to: fileURL)
            defer { try? FileManager.default.removeItem(at: fileURL) }

            try await PHPhotoLibrary.shared().performChanges {
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = false
                PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: fileURL, options: options)
            }
        }
    }
}
