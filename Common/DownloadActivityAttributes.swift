import ActivityKit
import Foundation

/// Data shown in the Dynamic Island / Lock Screen while Keepsake is saving.
struct DownloadActivityAttributes: ActivityAttributes {
    enum Phase: String, Codable, Hashable {
        case downloading
        case merging
        case saving
        case done
        case failed
    }

    struct ContentState: Codable, Hashable {
        var progress: Double
        var completed: Int
        var total: Int
        var phase: Phase
        var message: String
    }

    /// e.g. "@username"
    var title: String
    /// Platform display name, e.g. "Instagram".
    var platform: String
    /// SF Symbol for the platform.
    var symbol: String
}
