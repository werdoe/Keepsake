import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Timeline

struct RecentSavesEntry: TimelineEntry {
    let date: Date
    let saves: [HistoryEntry]
    let todayCount: Int
}

struct RecentSavesProvider: TimelineProvider {
    func placeholder(in context: Context) -> RecentSavesEntry {
        RecentSavesEntry(date: Date(), saves: [], todayCount: 0)
    }

    func getSnapshot(in context: Context, completion: @escaping (RecentSavesEntry) -> Void) {
        completion(makeEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RecentSavesEntry>) -> Void) {
        // The app and share sheet reload widgets after every save; refresh hourly for "today".
        completion(Timeline(entries: [makeEntry()], policy: .after(Date().addingTimeInterval(3600))))
    }

    private func makeEntry() -> RecentSavesEntry {
        let all = HistoryStore.readEntries()
        let today = all.filter { Calendar.current.isDateInToday($0.date) }.reduce(0) { $0 + $1.itemCount }
        return RecentSavesEntry(date: Date(), saves: Array(all.prefix(3)), todayCount: today)
    }
}

// MARK: - Widget

struct RecentSavesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "RecentSaves", provider: RecentSavesProvider()) { entry in
            RecentSavesView(entry: entry)
        }
        .configurationDisplayName("Keepsake")
        .description("Your latest saves, and a button to save the link on your clipboard.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular])
    }
}

struct RecentSavesView: View {
    let entry: RecentSavesEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "arrow.down")
                    .font(.system(size: 20, weight: .heavy, design: .rounded))
            }
            .widgetURL(URL(string: "keepsake://paste"))
            .containerBackground(for: .widget) { Color.clear }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Label("Keepsake", systemImage: "arrow.down.circle.fill")
                    .font(.headline)
                Text(entry.todayCount == 0 ? "Nothing saved today" : "\(entry.todayCount) saved today")
                    .font(.caption)
                if let last = entry.saves.first {
                    Text(last.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .widgetURL(URL(string: "keepsake://library"))
            .containerBackground(for: .widget) { Color.clear }
        case .systemMedium:
            medium
        default:
            small
        }
    }

    // MARK: Small

    private var small: some View {
        ZStack(alignment: .bottom) {
            if let last = entry.saves.first, let image = thumbnail(last) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .overlay(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom))
            }
            VStack(alignment: .leading, spacing: 8) {
                if entry.saves.isEmpty {
                    KeepsakeMark(size: 40, monochrome: true)
                    Spacer()
                } else {
                    Spacer()
                    Text(entry.saves.first?.title ?? "")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                pasteButton
            }
            .padding(12)
        }
        .widgetURL(URL(string: "keepsake://library"))
        .containerBackground(for: .widget) { Brand.gradient }
    }

    // MARK: Medium

    private var medium: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    KeepsakeMark(size: 26, monochrome: true)
                    Text("Keepsake").font(.headline).foregroundStyle(.white)
                }
                Text(entry.todayCount == 0 ? "Nothing saved today" : "\(entry.todayCount) saved today")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                Spacer(minLength: 0)
                pasteButton
            }
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { index in
                    Group {
                        if entry.saves.indices.contains(index), let image = thumbnail(entry.saves[index]) {
                            Image(uiImage: image).resizable().scaledToFill()
                        } else {
                            Color.white.opacity(0.15)
                        }
                    }
                    .frame(width: 58, height: 110)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
        .padding(14)
        .widgetURL(URL(string: "keepsake://library"))
        .containerBackground(for: .widget) { Brand.gradient }
    }

    private var pasteButton: some View {
        Button(intent: PasteAndSaveIntent()) {
            Label("Paste & Save", systemImage: "doc.on.clipboard.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(Brand.blue)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity)
                .background(.white, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func thumbnail(_ entry: HistoryEntry) -> UIImage? {
        guard let url = entry.thumbnailURL else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
}

// MARK: - Control Center (iOS 18)

@available(iOS 18.0, *)
struct PasteSaveControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.rai.igsaver.pastesave") {
            ControlWidgetButton(action: PasteAndSaveIntent()) {
                Label("Paste & Save", systemImage: "arrow.down.circle.fill")
            }
        }
        .displayName("Paste & Save")
        .description("Opens Keepsake and saves the link on your clipboard.")
    }
}
