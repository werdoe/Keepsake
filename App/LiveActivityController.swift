import ActivityKit
import Foundation

/// Shows save progress in the Dynamic Island and on the Lock Screen.
@MainActor
final class LiveActivityController {
    private var activity: Activity<DownloadActivityAttributes>?
    private var lastUpdate = Date.distantPast
    private var lastPhase: DownloadActivityAttributes.Phase?

    func start(title: String, platform: Platform, total: Int) {
        guard AppSettings.shared.liveActivities, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        endImmediately()
        let attributes = DownloadActivityAttributes(title: title, platform: platform.name, symbol: platform.symbol)
        let state = DownloadActivityAttributes.ContentState(progress: 0, completed: 0, total: total,
                                                            phase: .downloading, message: "Starting…")
        activity = try? Activity.request(attributes: attributes,
                                         content: ActivityContent(state: state, staleDate: nil),
                                         pushType: nil)
        lastUpdate = .distantPast
        lastPhase = nil
    }

    func update(_ progress: SaveProgress) {
        guard let activity else { return }
        let phase = Self.phase(for: progress.phase)
        // Updates are rate-limited by the system; only send meaningful changes.
        let now = Date()
        guard phase != lastPhase || now.timeIntervalSince(lastUpdate) > 0.5 else { return }
        lastUpdate = now
        lastPhase = phase
        let state = DownloadActivityAttributes.ContentState(progress: progress.fraction, completed: progress.completed,
                                                            total: progress.total, phase: phase, message: progress.message)
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    func finish(success: Bool, message: String, total: Int) {
        guard let activity else { return }
        let state = DownloadActivityAttributes.ContentState(progress: success ? 1 : 0, completed: success ? total : 0,
                                                            total: total, phase: success ? .done : .failed, message: message)
        self.activity = nil
        Task {
            await activity.end(ActivityContent(state: state, staleDate: nil),
                               dismissalPolicy: .after(Date().addingTimeInterval(4)))
        }
    }

    private func endImmediately() {
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    private static func phase(for phase: SaveProgress.Phase) -> DownloadActivityAttributes.Phase {
        switch phase {
        case .downloading: return .downloading
        case .merging: return .merging
        case .saving: return .saving
        case .done: return .done
        }
    }
}
