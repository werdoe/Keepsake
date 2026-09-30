import Foundation
import Photos
import UIKit

/// Adds downloaded files to the Photos library, optionally into a "Keepsake" album.
enum MediaSaver {
    private static let albumKey = "albumIdentifier"

    /// Asks for the access the current settings need. Returns whether saving into an album is possible.
    @discardableResult
    static func prepare(wantsAlbum: Bool) async throws -> Bool {
        if wantsAlbum {
            let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            if status == .authorized { return true }
            // Limited or denied full access: still try add-only saving without the album.
        }
        let addStatus = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard addStatus == .authorized || addStatus == .limited else { throw KeepsakeError.photosPermission }
        return false
    }

    /// Saves a local file and returns the new asset's identifier.
    static func save(file: URL, kind: MediaItem.Kind, intoAlbum: Bool) async throws -> String? {
        let album = intoAlbum ? try? await albumCollection() : nil
        let resourceURL: URL
        let resourceType: PHAssetResourceType
        switch kind {
        case .video:
            resourceURL = file
            resourceType = .video
        case .photo:
            resourceURL = try normalisedPhoto(file)
            resourceType = .photo
        }

        var identifier: String?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = false
            request.addResource(with: resourceType, fileURL: resourceURL, options: options)
            identifier = request.placeholderForCreatedAsset?.localIdentifier
            if let album, let placeholder = request.placeholderForCreatedAsset,
               let change = PHAssetCollectionChangeRequest(for: album) {
                change.addAssets([placeholder] as NSArray)
            }
        }
        if resourceURL != file { try? FileManager.default.removeItem(at: resourceURL) }
        return identifier
    }

    /// Photos accepts JPEG/HEIC/PNG directly; anything else (e.g. WebP) is converted to JPEG.
    private static func normalisedPhoto(_ file: URL) throws -> URL {
        let data = try Data(contentsOf: file)
        let isJPEG = data.starts(with: [0xFF, 0xD8, 0xFF])
        let isPNG = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
        let isHEIC = data.count > 12 && String(data: data[4..<12], encoding: .ascii)?.contains("ftyphei") == true
        let ext = isPNG ? "png" : isHEIC ? "heic" : "jpg"
        let target = file.deletingPathExtension().appendingPathExtension(ext + ".photo." + ext)
        if isJPEG || isPNG || isHEIC {
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: file, to: target)
            return target
        }
        guard let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.95) else {
            throw KeepsakeError.downloadFailed
        }
        try jpeg.write(to: target)
        return target
    }

    private static func albumCollection() async throws -> PHAssetCollection? {
        let defaults = AppGroup.defaults
        if let id = defaults.string(forKey: albumKey),
           let existing = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject {
            return existing
        }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title = %@", Brand.name)
        if let found = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: options).firstObject {
            defaults.set(found.localIdentifier, forKey: albumKey)
            return found
        }
        var placeholderID: String?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: Brand.name)
            placeholderID = request.placeholderForCreatedAssetCollection.localIdentifier
        }
        guard let placeholderID else { return nil }
        defaults.set(placeholderID, forKey: albumKey)
        return PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [placeholderID], options: nil).firstObject
    }
}
