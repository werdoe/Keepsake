import ActivityKit
import SwiftUI
import WidgetKit

@main
struct KeepsakeWidgets: WidgetBundle {
    var body: some Widget {
        DownloadLiveActivity()
    }
}

/// Download progress in the Dynamic Island and on the Lock Screen.
struct DownloadLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            LockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    KeepsakeMark(size: 40)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    StatusGlyph(state: context.state)
                        .frame(width: 40, height: 40)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(context.attributes.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(context.state.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ProgressView(value: context.state.progress)
                        .tint(tint(for: context.state.phase))
                        .padding(.horizontal, 8)
                        .padding(.top, 4)
                }
            } compactLeading: {
                KeepsakeMark(size: 22, monochrome: true)
            } compactTrailing: {
                StatusGlyph(state: context.state)
                    .frame(width: 20, height: 20)
            } minimal: {
                StatusGlyph(state: context.state)
                    .frame(width: 20, height: 20)
            }
            .keylineTint(Brand.blue)
        }
    }

    private func tint(for phase: DownloadActivityAttributes.Phase) -> Color {
        switch phase {
        case .done: return .green
        case .failed: return .orange
        default: return Brand.blue
        }
    }
}

/// Progress ring while working, then a checkmark or warning.
private struct StatusGlyph: View {
    let state: DownloadActivityAttributes.ContentState

    var body: some View {
        switch state.phase {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.orange)
        default:
            ZStack {
                Circle().stroke(Color.white.opacity(0.25), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: max(0.03, state.progress))
                    .stroke(Brand.gradient, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .padding(2)
        }
    }
}

private struct LockScreenView: View {
    let context: ActivityViewContext<DownloadActivityAttributes>

    var body: some View {
        HStack(spacing: 14) {
            KeepsakeMark(size: 44)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(context.attributes.platform, systemImage: context.attributes.symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    if context.state.phase != .done && context.state.phase != .failed {
                        Text("\(Int(context.state.progress * 100))%")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                Text(context.attributes.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(context.state.message)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
                if context.state.phase != .done && context.state.phase != .failed {
                    ProgressView(value: context.state.progress)
                        .tint(Brand.blue)
                }
            }
        }
        .padding(16)
    }
}
