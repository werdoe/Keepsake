import Foundation

/// One downloadable photo or video.
struct MediaItem: Identifiable, Hashable {
    enum Kind: Hashable { case photo, video }

    let id = UUID()
    let kind: Kind
    /// Full-resolution file.
    let url: URL
    /// Still image used for the preview grid (for photos this is the photo itself).
    let thumbnailURL: URL
    let width: Int
    let height: Int
}

/// Everything found behind one link.
struct FetchResult {
    let title: String
    let items: [MediaItem]
}
