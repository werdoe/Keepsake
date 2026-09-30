import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes the caption, source link and original date into a photo's metadata
/// (IPTC caption, TIFF description and EXIF), so they travel with the file.
enum MetadataWriter {
    static func embed(into photo: URL, caption: String?, source: URL, date: Date?) -> URL {
        guard let imageSource = CGImageSourceCreateWithURL(photo as CFURL, nil),
              let type = CGImageSourceGetType(imageSource) else { return photo }

        let text = [caption, source.absoluteString].compactMap { $0 }.joined(separator: "\n\n")
        var properties = (CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]) ?? [:]

        var iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
        iptc[kCGImagePropertyIPTCCaptionAbstract] = text
        iptc[kCGImagePropertyIPTCSource] = source.absoluteString
        properties[kCGImagePropertyIPTCDictionary] = iptc

        var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        tiff[kCGImagePropertyTIFFImageDescription] = text
        properties[kCGImagePropertyTIFFDictionary] = tiff

        var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        exif[kCGImagePropertyExifUserComment] = text
        if let date {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            exif[kCGImagePropertyExifDateTimeOriginal] = formatter.string(from: date)
        }
        properties[kCGImagePropertyExifDictionary] = exif

        let output = photo.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(photo.pathExtension.isEmpty ? "jpg" : photo.pathExtension)
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, type, 1, nil) else { return photo }
        CGImageDestinationAddImageFromSource(destination, imageSource, 0, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return photo }
        try? FileManager.default.removeItem(at: photo)
        return output
    }
}
