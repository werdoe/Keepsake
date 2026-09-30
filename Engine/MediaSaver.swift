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

    /// Which album (if any) new saves go into.
    enum AlbumTarget {
        /// One "Keepsake" album.
        case keepsake
        /// An album per account (e.g. "@username") inside a "Keepsake" folder.
        case account(String)
    }

    /// Saves a local file to Photos and returns the new asset's identifier.
    static func save(file: URL, kind: MediaItem.Kind, album target: AlbumTarget?, creationDate: Date?) async throws -> String? {
        var album: PHAssetCollection?
        switch target {
        case .keepsake: album = try? await albumCollection()
        case .account(let name): album = try? await accountAlbum(named: name)
        case nil: album = nil
        }
        var identifier: String?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = false
            request.addResource(with: kind == .video ? .video : .photo, fileURL: file, options: options)
            if let creationDate { request.creationDate = creationDate }
            identifier = request.placeholderForCreatedAsset?.localIdentifier
            if let album, let placeholder = request.placeholderForCreatedAsset,
               let change = PHAssetCollectionChangeRequest(for: album) {
                change.addAssets([placeholder] as NSArray)
            }
        }
        return identifier
    }

    // MARK: - Per-account albums (Photos › Albums › Keepsake › @username)

    private static let folderKey = "albumFolderIdentifier"
    private static let accountAlbumsKey = "accountAlbumIdentifiers"

    private static func keepsakeFolder() async throws -> PHCollectionList? {
        let defaults = AppGroup.defaults
        if let id = defaults.string(forKey: folderKey),
           let existing = PHCollectionList.fetchCollectionLists(withLocalIdentifiers: [id], options: nil).firstObject {
            return existing
        }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title = %@", Brand.name)
        if let found = PHCollectionList.fetchCollectionLists(with: .folder, subtype: .any, options: options).firstObject {
            defaults.set(found.localIdentifier, forKey: folderKey)
            return found
        }
        var placeholderID: String?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHCollectionListChangeRequest.creationRequestForCollectionList(withTitle: Brand.name)
            placeholderID = request.placeholderForCreatedCollectionList.localIdentifier
        }
        guard let placeholderID else { return nil }
        defaults.set(placeholderID, forKey: folderKey)
        return PHCollectionList.fetchCollectionLists(withLocalIdentifiers: [placeholderID], options: nil).firstObject
    }

    private static func accountAlbum(named rawName: String) async throws -> PHAssetCollection? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Other" : rawName
        let defaults = AppGroup.defaults
        var known = defaults.dictionary(forKey: accountAlbumsKey) as? [String: String] ?? [:]
        if let id = known[name],
           let existing = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject {
            return existing
        }
        guard let folder = try await keepsakeFolder() else { return nil }
        let children = PHCollection.fetchCollections(in: folder, options: nil)
        var found: PHAssetCollection?
        children.enumerateObjects { collection, _, stop in
            if let album = collection as? PHAssetCollection, album.localizedTitle == name {
                found = album
                stop.pointee = true
            }
        }
        if let found {
            known[name] = found.localIdentifier
            defaults.set(known, forKey: accountAlbumsKey)
            return found
        }
        var placeholderID: String?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
            let placeholder = request.placeholderForCreatedAssetCollection
            placeholderID = placeholder.localIdentifier
            PHCollectionListChangeRequest(for: folder)?.addChildCollections([placeholder] as NSArray)
        }
        guard let placeholderID else { return nil }
        known[name] = placeholderID
        defaults.set(known, forKey: accountAlbumsKey)
        return PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [placeholderID], options: nil).firstObject
    }

    /// Photos accepts JPEG/HEIC/PNG directly; anything else (e.g. WebP) is converted to JPEG.
    /// Returns a file with the right extension.
    static func normalisedPhoto(_ file: URL) throws -> URL {
        let data = try Data(contentsOf: file)
        let isJPEG = data.starts(with: [0xFF, 0xD8, 0xFF])
        let isPNG = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
        let isHEIC = data.count > 12 && String(data: data.subdata(in: 4..<12), encoding: .ascii)?.contains("ftyphei") == true
        let base = file.deletingPathExtension()
        if isJPEG || isPNG || isHEIC {
            let target = base.appendingPathExtension(isPNG ? "png" : isHEIC ? "heic" : "jpg")
            if target != file {
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: file, to: target)
            }
            return target
        }
        guard let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.95) else {
            throw KeepsakeError.downloadFailed
        }
        let target = base.appendingPathExtension("converted.jpg")
        try jpeg.write(to: target)
        try? FileManager.default.removeItem(at: file)
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
