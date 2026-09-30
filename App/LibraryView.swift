import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var history: HistoryStore
    @EnvironmentObject private var model: SaveModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.scenePhase) private var scenePhase
    @Binding var selectedTab: RootView.Tab

    @State private var unlocked = false

    @State private var search = ""
    @State private var selected: HistoryEntry?
    @State private var confirmClear = false
    @State private var filter: Platform?

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    private var filtered: [HistoryEntry] {
        history.entries.filter { entry in
            (filter == nil || entry.platform == filter)
                && (search.isEmpty
                    || entry.title.localizedCaseInsensitiveContains(search)
                    || (entry.caption?.localizedCaseInsensitiveContains(search) ?? false))
        }
    }

    var body: some View {
        Group {
            if settings.lockLibrary && !unlocked {
                lockedView
            } else {
                library
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { unlocked = false }
        }
    }

    private var lockedView: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: LibraryLock.biometrySymbol)
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(Brand.gradient)
                .symbolEffect(.pulse, options: .repeating)
            Text("Library is locked").font(.title2.weight(.bold))
            Text("Unlock with \(LibraryLock.biometryName) to see your saves.")
                .foregroundStyle(.secondary)
            Button {
                unlock()
            } label: {
                Label("Unlock", systemImage: "lock.open.fill")
            }
            .buttonStyle(GradientButtonStyle(height: 50))
            .frame(maxWidth: 240)
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AuroraBackground(intensity: 0.8))
        .onAppear { unlock() }
    }

    private func unlock() {
        Task {
            if await LibraryLock.authenticate(reason: "Unlock your Library") {
                withAnimation(.snappy) { unlocked = true }
            }
        }
    }

    private var library: some View {
        NavigationStack {
            Group {
                if history.entries.isEmpty {
                    ContentUnavailableView {
                        Label {
                            Text("Nothing saved yet")
                        } icon: {
                            KeepsakeMark(size: 64, fanned: true)
                        }
                    } description: {
                        Text("Everything you save shows up here, including saves from the share sheet.")
                    } actions: {
                        Button("Save Something") { selectedTab = .save }
                            .buttonStyle(.borderedProminent)
                            .tint(Brand.blue)
                    }
                } else {
                    ScrollView {
                        filterBar
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(filtered) { entry in
                                Button {
                                    selected = entry
                                } label: {
                                    HistoryCard(entry: entry)
                                }
                                .buttonStyle(PressableStyle())
                                .contextMenu {
                                    Link(destination: entry.sourceURL) {
                                        Label("Open Original", systemImage: "safari")
                                    }
                                    Button {
                                        UIPasteboard.general.url = entry.sourceURL
                                    } label: {
                                        Label("Copy Link", systemImage: "link")
                                    }
                                    Button(role: .destructive) {
                                        withAnimation(.snappy) { history.remove(entry) }
                                    } label: {
                                        Label("Remove", systemImage: "trash")
                                    }
                                }
                                .transition(.scale(scale: 0.9).combined(with: .opacity))
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)
                        .animation(.snappy, value: filtered)
                    }
                    .searchable(text: $search, prompt: "Search saves")
                }
            }
            .navigationTitle("Library")
            .background(Color(.systemGroupedBackground))
            .toolbar {
                if !history.entries.isEmpty {
                    Menu {
                        Button(role: .destructive) { confirmClear = true } label: {
                            Label("Clear Library", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .confirmationDialog("Clear your Library?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear Library", role: .destructive) { withAnimation { history.clear() } }
            } message: {
                Text("This only clears Keepsake's list. Your photos and videos stay in Photos.")
            }
            .sheet(item: $selected) { entry in
                HistoryDetail(entry: entry) {
                    selected = nil
                    model.paste(entry.sourceURL.absoluteString)
                    selectedTab = .save
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .refreshable { history.reload() }
        }
        .onAppear { history.reload() }
    }

    /// Filter chips that fit the width: names when there's room, otherwise the selected
    /// platform keeps its name and the others show just their icon.
    private var filterBar: some View {
        ViewThatFits(in: .horizontal) {
            filterRow(compact: false)
            filterRow(compact: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func filterRow(compact: Bool) -> some View {
        HStack(spacing: 8) {
            chip(title: "All", symbol: "square.grid.2x2", isOn: filter == nil, iconOnly: false) { filter = nil }
            ForEach(Platform.allCases) { platform in
                chip(title: platform.name, symbol: platform.symbol, isOn: filter == platform,
                     iconOnly: compact && filter != platform) {
                    filter = filter == platform ? nil : platform
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func chip(title: String, symbol: String, isOn: Bool, iconOnly: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.snappy) { action() }
        } label: {
            Label(title, systemImage: symbol)
                .labelStyle(iconOnly ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .foregroundStyle(isOn ? .white : .primary)
                .background(isOn ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Color(.secondarySystemGroupedBackground)),
                            in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct HistoryCard: View {
    let entry: HistoryEntry

    var body: some View {
        Color.clear
            .aspectRatio(0.8, contentMode: .fit)
            .overlay { LocalImage(url: entry.thumbnailURL).allowsHitTesting(false) }
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(entry.date, format: .relative(presentation: .named))
                        .font(.caption2)
                        .opacity(0.8)
                }
                .foregroundStyle(.white)
                .padding(10)
            }
            .overlay(alignment: .topLeading) {
                PlatformBadge(platform: entry.platform, compact: true)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(8)
            }
            .overlay(alignment: .topTrailing) {
                if entry.itemCount > 1 {
                    Label("\(entry.itemCount)", systemImage: "square.stack.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.4), in: Capsule())
                        .padding(8)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            // Thumbnails are scaled to fill and spill past the card; keep taps inside the card.
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
    }
}

private struct HistoryDetail: View {
    let entry: HistoryEntry
    var onSaveAgain: () -> Void

    @EnvironmentObject private var history: HistoryStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @State private var copiedMessage: String?
    @State private var copyTick = 0

    private func hashtags(in caption: String) -> [String] {
        MediaBundle(platform: entry.platform, title: "", caption: caption, sourceURL: entry.sourceURL, items: []).hashtags
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                LocalImage(url: entry.thumbnailURL)
                    .frame(height: 220)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    PlatformBadge(platform: entry.platform)
                    Text(entry.title).font(.title2.weight(.bold))
                    HStack(spacing: 6) {
                        Text(entry.date, style: .date)
                        Text("·")
                        Text(summary)
                        if let q = entry.qualityLabel { QualityPill(text: q) }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    if let caption = entry.caption {
                        CaptionCard(caption: caption, hashtags: hashtags(in: caption)) { text, label in
                            UIPasteboard.general.string = text
                            copiedMessage = label
                            copyTick += 1
                        }
                        .padding(.top, 4)
                    }
                    if let copiedMessage {
                        Label(copiedMessage, systemImage: "checkmark.circle.fill")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.green)
                            .transition(.opacity)
                    }
                }

                VStack(spacing: 10) {
                    Button {
                        if let url = URL(string: "photos-redirect://") { openURL(url) }
                    } label: {
                        Label("Open Photos", systemImage: "photo.on.rectangle")
                    }
                    .buttonStyle(GradientButtonStyle(height: 50))

                    HStack(spacing: 10) {
                        Button {
                            openURL(entry.sourceURL)
                        } label: {
                            Label("Original", systemImage: "safari").frame(maxWidth: .infinity)
                        }
                        Button {
                            onSaveAgain()
                        } label: {
                            Label("Save Again", systemImage: "arrow.down.circle").frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    Button(role: .destructive) {
                        history.remove(entry)
                        dismiss()
                    } label: {
                        Label("Remove from Library", systemImage: "trash").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
            .padding(20)
            .animation(.snappy, value: copiedMessage)
        }
        .sensoryFeedback(.impact(weight: .light), trigger: copyTick) { _, _ in settings.haptics }
    }

    private var summary: String {
        var parts: [String] = []
        if entry.photoCount > 0 { parts.append("\(entry.photoCount) photo\(entry.photoCount == 1 ? "" : "s")") }
        if entry.videoCount > 0 { parts.append("\(entry.videoCount) video\(entry.videoCount == 1 ? "" : "s")") }
        return parts.joined(separator: ", ")
    }
}
