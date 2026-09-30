import Photos
import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var history: HistoryStore
    @EnvironmentObject private var model: SaveModel
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var collections = CollectionsStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @Binding var selectedTab: RootView.Tab

    enum Mode: String, CaseIterable, Identifiable {
        case saves = "Saves", accounts = "Accounts", collections = "Collections"
        var id: String { rawValue }
    }

    enum SortOrder: String, CaseIterable, Identifiable {
        case newest = "Newest First", oldest = "Oldest First", account = "By Account", platform = "By Platform"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .newest: return "arrow.down"
            case .oldest: return "arrow.up"
            case .account: return "person.crop.square"
            case .platform: return "square.grid.2x2"
            }
        }
    }

    @State private var unlocked = false
    @State private var mode: Mode = .saves
    @AppStorage("librarySort") private var sortRaw = SortOrder.newest.rawValue
    @State private var favoritesOnly = false
    @State private var search = ""
    @State private var selected: HistoryEntry?
    @State private var confirmClear = false
    @State private var filter: Platform?

    // Select mode
    @State private var selecting = false
    @State private var selection: Set<UUID> = []
    @State private var confirmBulkDelete = false
    @State private var showAddToCollection = false
    @State private var shareItem: ShareItem?
    @State private var preparingShare = false

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    private var sort: SortOrder { SortOrder(rawValue: sortRaw) ?? .newest }

    private var filtered: [HistoryEntry] {
        history.entries.filter { entry in
            (filter == nil || entry.platform == filter)
                && (!favoritesOnly || entry.favorite)
                && (search.isEmpty
                    || entry.title.localizedCaseInsensitiveContains(search)
                    || (entry.caption?.localizedCaseInsensitiveContains(search) ?? false))
        }
    }

    /// Filtered saves, sorted and split into sections.
    private var sections: [SaveSection] {
        SaveSection.make(filtered, sort: sort)
    }

    private var selectedEntries: [HistoryEntry] {
        history.entries.filter { selection.contains($0.id) }
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
                        Picker("View", selection: $mode) {
                            ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                        if mode != .collections { filterBar }
                        switch mode {
                        case .saves:
                            SavesGrid(sections: sections, selecting: selecting, selection: $selection) { selected = $0 }
                        case .accounts:
                            accountsGrid
                        case .collections:
                            CollectionsGrid()
                                .padding(.top, 8)
                        }
                    }
                    .searchable(text: $search, prompt: "Search saves and captions")
                    .safeAreaInset(edge: .bottom) {
                        if selecting { selectionBar }
                    }
                }
            }
            .navigationTitle("Library")
            .background(Color(.systemGroupedBackground))
            .toolbar {
                if !history.entries.isEmpty {
                    if mode == .saves {
                        ToolbarItem(placement: .topBarLeading) {
                            Button(selecting ? "Done" : "Select") {
                                withAnimation(.snappy) {
                                    selecting.toggle()
                                    selection = []
                                }
                            }
                            .fontWeight(selecting ? .semibold : .regular)
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Picker("Sort", selection: $sortRaw) {
                                ForEach(SortOrder.allCases) { order in
                                    Label(order.rawValue, systemImage: order.symbol).tag(order.rawValue)
                                }
                            }
                            Divider()
                            Button(role: .destructive) { confirmClear = true } label: {
                                Label("Clear Library", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "arrow.up.arrow.down.circle")
                        }
                    }
                }
            }
            .confirmationDialog("Clear your Library?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear Library", role: .destructive) { withAnimation { history.clear() } }
            } message: {
                Text("This only clears Keepsake's list. Your photos and videos stay in Photos.")
            }
            .confirmationDialog("Delete \(selection.count) save\(selection.count == 1 ? "" : "s")?",
                                isPresented: $confirmBulkDelete, titleVisibility: .visible) {
                Button("Remove from Keepsake Library", role: .destructive) { deleteSelection(fromPhotos: false) }
                if selectedEntries.contains(where: { !$0.assetIdentifiers.isEmpty }) {
                    Button("Delete from Photos too", role: .destructive) { deleteSelection(fromPhotos: true) }
                }
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
            .sheet(isPresented: $showAddToCollection) {
                AddToCollectionSheet(entryIDs: Array(selection)) {
                    withAnimation(.snappy) {
                        selecting = false
                        selection = []
                    }
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(item: $shareItem) { item in ShareSheet(items: item.items) }
            .refreshable { history.reload() }
        }
        .onAppear {
            history.reload()
            collections.prune(existing: Set(history.entries.map(\.id)))
        }
    }

    // MARK: - Select mode

    private var selectionBar: some View {
        HStack(spacing: 0) {
            bulkAction("square.and.arrow.up", preparingShare ? "Preparing…" : "Share") { shareSelection() }
            bulkAction("heart", "Favourite") {
                let makeFavourite = selectedEntries.contains { !$0.favorite }
                for entry in selectedEntries where entry.favorite != makeFavourite { history.toggleFavorite(entry) }
            }
            bulkAction("rectangle.stack.badge.plus", "Collect") { showAddToCollection = true }
            bulkAction("trash", "Delete", tint: .red) { confirmBulkDelete = true }
        }
        .disabled(selection.isEmpty)
        .opacity(selection.isEmpty ? 0.45 : 1)
        .padding(.vertical, 10)
        .overlay(alignment: .top) {
            Text(selection.isEmpty ? "Tap saves to select them" : "\(selection.count) selected")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .offset(y: -22)
        }
        .padding(.top, 18)
        .background(.bar)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func bulkAction(_ symbol: String, _ title: String, tint: Color = Brand.blue, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.title3)
                Text(title).font(.caption2.weight(.medium))
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PressableStyle())
    }

    private func shareSelection() {
        guard !preparingShare else { return }
        preparingShare = true
        let pages = LibraryPage.pages(for: selectedEntries)
        Task {
            var items: [Any] = []
            for page in pages.prefix(60) {
                items += await SavedMediaExporter.shareItems(for: page.ref, fallback: page.entry.sourceURL)
            }
            await MainActor.run {
                preparingShare = false
                shareItem = ShareItem(items: items)
            }
        }
    }

    private func deleteSelection(fromPhotos: Bool) {
        let entries = selectedEntries
        Task {
            if fromPhotos {
                let ids = entries.flatMap(\.assetIdentifiers)
                let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
                try? await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(assets) }
            }
            await MainActor.run {
                withAnimation(.snappy) {
                    for entry in entries { history.remove(entry) }
                    selection = []
                    selecting = false
                }
            }
        }
    }

    // MARK: - Accounts

    private var accountGroups: [AccountGroup] {
        let grouped = Dictionary(grouping: filtered) { "\($0.platform.rawValue)|\($0.account)" }
        return grouped.map { key, entries in
            AccountGroup(id: key, name: entries[0].account, platform: entries[0].platform,
                         entries: entries.sorted { $0.date > $1.date })
        }
        .sorted { ($0.entries.first?.date ?? .distantPast) > ($1.entries.first?.date ?? .distantPast) }
    }

    private var accountsGrid: some View {
        LazyVGrid(columns: columns, spacing: 14) {
            ForEach(accountGroups) { group in
                NavigationLink {
                    AccountDetailView(group: group) { selected = $0 }
                } label: {
                    AccountFolderCard(group: group)
                }
                .buttonStyle(PressableStyle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
    }

    // MARK: - Filters

    /// A platform menu and a Favourites toggle: two fixed-size buttons that always fit.
    private var filterBar: some View {
        HStack(spacing: 8) {
            Menu {
                Button {
                    withAnimation(.snappy) { filter = nil }
                } label: {
                    if filter == nil {
                        Label("All Platforms", systemImage: "checkmark")
                    } else {
                        Label("All Platforms", systemImage: "square.grid.2x2")
                    }
                }
                Divider()
                ForEach(Platform.allCases) { platform in
                    Button {
                        withAnimation(.snappy) { filter = platform }
                    } label: {
                        if filter == platform {
                            Label(platform.name, systemImage: "checkmark")
                        } else {
                            Label(platform.name, systemImage: platform.symbol)
                        }
                    }
                }
            } label: {
                filterCapsule(title: filter?.name ?? "All Platforms", symbol: filter?.symbol ?? "square.grid.2x2",
                              isOn: filter != nil, menu: true)
            }

            Button {
                withAnimation(.snappy) { favoritesOnly.toggle() }
            } label: {
                filterCapsule(title: "Favourites", symbol: favoritesOnly ? "heart.fill" : "heart", isOn: favoritesOnly, menu: false)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Text("\(filtered.count)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .animation(.snappy, value: filtered.count)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func filterCapsule(title: String, symbol: String, isOn: Bool, menu: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
            Text(title).lineLimit(1)
            if menu {
                Image(systemName: "chevron.down").font(.caption2.weight(.bold))
            }
        }
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .foregroundStyle(isOn ? .white : .primary)
        .background(isOn ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Color(.secondarySystemGroupedBackground)),
                    in: Capsule())
        .fixedSize()
        .contentShape(Capsule())
    }
}

// MARK: - Sections

struct SaveSection: Identifiable, Hashable {
    let id: String
    let title: String?
    let entries: [HistoryEntry]

    static func make(_ entries: [HistoryEntry], sort: LibraryView.SortOrder) -> [SaveSection] {
        switch sort {
        case .newest, .oldest:
            let ordered = sort == .newest ? entries.sorted { $0.date > $1.date } : entries.sorted { $0.date < $1.date }
            var sections: [SaveSection] = []
            for entry in ordered {
                let title = dateBucket(entry.date)
                if let last = sections.last, last.title == title {
                    sections[sections.count - 1] = SaveSection(id: last.id, title: title, entries: last.entries + [entry])
                } else {
                    sections.append(SaveSection(id: title, title: title, entries: [entry]))
                }
            }
            return sections
        case .account:
            let grouped = Dictionary(grouping: entries) { $0.account }
            return grouped.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }.map { key in
                SaveSection(id: key, title: key, entries: grouped[key]!.sorted { $0.date > $1.date })
            }
        case .platform:
            return Platform.allCases.compactMap { platform in
                let items = entries.filter { $0.platform == platform }.sorted { $0.date > $1.date }
                return items.isEmpty ? nil : SaveSection(id: platform.rawValue, title: platform.name, entries: items)
            }
        }
    }

    private static func dateBucket(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: Date())).day,
           days < 7 { return "This Week" }
        if calendar.isDate(date, equalTo: Date(), toGranularity: .month) { return "This Month" }
        return date.formatted(.dateTime.month(.wide).year())
    }
}

/// Sectioned grid of saves. Tapping opens the full-screen viewer (which swipes through
/// everything shown, in order); in select mode, tapping toggles selection.
struct SavesGrid: View {
    let sections: [SaveSection]
    var selecting: Bool = false
    @Binding var selection: Set<UUID>
    var onDetails: (HistoryEntry) -> Void

    @EnvironmentObject private var history: HistoryStore
    @EnvironmentObject private var settings: AppSettings
    @State private var viewerStart: ViewerStart?
    @State private var collectEntry: HistoryEntry?

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    init(sections: [SaveSection], selecting: Bool = false, selection: Binding<Set<UUID>> = .constant([]),
         onDetails: @escaping (HistoryEntry) -> Void) {
        self.sections = sections
        self.selecting = selecting
        self._selection = selection
        self.onDetails = onDetails
    }

    init(entries: [HistoryEntry], onDetails: @escaping (HistoryEntry) -> Void) {
        self.init(sections: [SaveSection(id: "all", title: nil, entries: entries)], onDetails: onDetails)
    }

    private var allEntries: [HistoryEntry] { sections.flatMap(\.entries) }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12, pinnedViews: [.sectionHeaders]) {
            ForEach(sections) { section in
                Section {
                    ForEach(section.entries) { entry in
                        card(entry)
                    }
                } header: {
                    if let title = section.title {
                        HStack {
                            Text(title).font(.headline)
                            Text("\(section.entries.count)").font(.subheadline).foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 4)
                        .background(Color(.systemGroupedBackground).opacity(0.96))
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
        .animation(.snappy, value: sections)
        .fullScreenCover(item: $viewerStart) { start in
            LibraryViewer(start: start)
                .environmentObject(history)
                .environmentObject(settings)
        }
        .sheet(item: $collectEntry) { entry in
            AddToCollectionSheet(entryIDs: [entry.id]) {}
                .presentationDetents([.medium, .large])
        }
    }

    private func card(_ entry: HistoryEntry) -> some View {
        let isSelected = selection.contains(entry.id)
        return Button {
            if selecting {
                if isSelected { selection.remove(entry.id) } else { selection.insert(entry.id) }
            } else {
                viewerStart = ViewerStart(entries: allEntries, startEntryID: entry.id)
            }
        } label: {
            HistoryCard(entry: entry)
                .overlay {
                    if selecting {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(isSelected ? Brand.blue : .clear, lineWidth: 3)
                            .background(isSelected ? Color.black.opacity(0.15) : .clear,
                                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay(alignment: .topTrailing) {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .font(.title2)
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, isSelected ? Brand.blue : .black.opacity(0.25))
                                    .padding(8)
                            }
                            .allowsHitTesting(false)
                    }
                }
                .scaleEffect(selecting && isSelected ? 0.95 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isSelected)
        }
        .buttonStyle(PressableStyle())
        .contextMenu {
            if !selecting {
                Button {
                    history.toggleFavorite(entry)
                } label: {
                    Label(entry.favorite ? "Remove from Favourites" : "Add to Favourites",
                          systemImage: entry.favorite ? "heart.slash" : "heart")
                }
                Button {
                    collectEntry = entry
                } label: {
                    Label("Add to Collection", systemImage: "rectangle.stack.badge.plus")
                }
                Button {
                    onDetails(entry)
                } label: {
                    Label("Details", systemImage: "info.circle")
                }
                Link(destination: entry.sourceURL) {
                    Label("Open Original", systemImage: "safari")
                }
                Button {
                    UIPasteboard.general.url = entry.sourceURL
                } label: {
                    Label("Copy Link", systemImage: "link")
                }
                if let caption = entry.caption {
                    Button {
                        UIPasteboard.general.string = caption
                    } label: {
                        Label("Copy Caption", systemImage: "text.quote")
                    }
                }
                Button(role: .destructive) {
                    withAnimation(.snappy) { history.remove(entry) }
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            }
        }
    }
}

// MARK: - Collections

struct CollectionsGrid: View {
    @EnvironmentObject private var history: HistoryStore
    @StateObject private var store = CollectionsStore.shared
    @State private var showNew = false
    @State private var editing: SaveCollection?

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 14) {
            Button { showNew = true } label: {
                VStack(spacing: 10) {
                    Image(systemName: "plus")
                        .font(.title.weight(.semibold))
                        .foregroundStyle(Brand.gradient)
                    Text("New Collection").font(.subheadline.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])).foregroundStyle(.secondary.opacity(0.5)))
            }
            .buttonStyle(PressableStyle())

            ForEach(store.collections) { collection in
                NavigationLink {
                    CollectionDetailView(collectionID: collection.id)
                } label: {
                    CollectionCard(collection: collection, entries: entries(of: collection))
                }
                .buttonStyle(PressableStyle())
                .contextMenu {
                    Button { editing = collection } label: { Label("Rename", systemImage: "pencil") }
                    Button(role: .destructive) { withAnimation { store.delete(collection) } } label: {
                        Label("Delete Collection", systemImage: "trash")
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
        .sheet(isPresented: $showNew) {
            CollectionEditor(title: "New Collection") { name, symbol in store.create(name: name, symbol: symbol) }
                .presentationDetents([.medium])
        }
        .sheet(item: $editing) { collection in
            CollectionEditor(title: "Rename", name: collection.name, symbol: collection.symbol) { name, symbol in
                store.rename(collection, to: name, symbol: symbol)
            }
            .presentationDetents([.medium])
        }
    }

    private func entries(of collection: SaveCollection) -> [HistoryEntry] {
        collection.entryIDs.compactMap { id in history.entries.first { $0.id == id } }
    }
}

struct CollectionCard: View {
    let collection: SaveCollection
    let entries: [HistoryEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let first = entries.first {
                        LocalImage(url: first.thumbnailURL).allowsHitTesting(false)
                    } else {
                        ZStack {
                            Brand.softGradient
                            Image(systemName: collection.symbol).font(.largeTitle).foregroundStyle(Brand.gradient)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(alignment: .topLeading) {
                    Image(systemName: collection.symbol)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Brand.gradient, in: Circle())
                        .padding(8)
                }
                .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
            VStack(alignment: .leading, spacing: 1) {
                Text(collection.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                Text("\(entries.count) save\(entries.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
    }
}

struct CollectionDetailView: View {
    let collectionID: UUID
    @EnvironmentObject private var history: HistoryStore
    @StateObject private var store = CollectionsStore.shared
    @State private var detail: HistoryEntry?

    private var collection: SaveCollection? { store.collections.first { $0.id == collectionID } }
    private var entries: [HistoryEntry] {
        (collection?.entryIDs ?? []).compactMap { id in history.entries.first { $0.id == id } }
    }

    var body: some View {
        ScrollView {
            if entries.isEmpty {
                ContentUnavailableView("Empty collection", systemImage: collection?.symbol ?? "rectangle.stack",
                                       description: Text("Long-press a save, or use Select in the Library, and choose Add to Collection."))
                    .padding(.top, 60)
            } else {
                SavesGrid(entries: entries) { detail = $0 }
                    .padding(.top, 8)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(collection?.name ?? "Collection")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $detail) { entry in
            HistoryDetail(entry: entry) {}
                .presentationDetents([.medium, .large])
        }
    }
}

/// Pick (or create) a collection for some saves.
struct AddToCollectionSheet: View {
    let entryIDs: [UUID]
    var onDone: () -> Void
    @StateObject private var store = CollectionsStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var newSymbol = CollectionsStore.symbols[0]

    var body: some View {
        NavigationStack {
            List {
                Section("New Collection") {
                    HStack {
                        TextField("Name", text: $newName)
                        Button("Create") {
                            store.create(name: newName, symbol: newSymbol, entryIDs: entryIDs)
                            finish()
                        }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    SymbolPicker(selection: $newSymbol)
                }
                if !store.collections.isEmpty {
                    Section("Add to") {
                        ForEach(store.collections) { collection in
                            Button {
                                store.add(entryIDs, to: collection)
                                finish()
                            } label: {
                                HStack {
                                    Image(systemName: collection.symbol)
                                        .foregroundStyle(.white)
                                        .frame(width: 30, height: 30)
                                        .background(Brand.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    Text(collection.name).foregroundStyle(.primary)
                                    Spacer()
                                    Text("\(collection.entryIDs.count)").foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add \(entryIDs.count == 1 ? "Save" : "\(entryIDs.count) Saves")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func finish() {
        onDone()
        dismiss()
    }
}

struct CollectionEditor: View {
    let title: String
    @State var name: String = ""
    @State var symbol: String = CollectionsStore.symbols[0]
    var onSave: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss

    init(title: String, name: String = "", symbol: String = CollectionsStore.symbols[0], onSave: @escaping (String, String) -> Void) {
        self.title = title
        self._name = State(initialValue: name)
        self._symbol = State(initialValue: symbol)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                SymbolPicker(selection: $symbol)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(name, symbol)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

struct SymbolPicker: View {
    @Binding var selection: String

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 10) {
            ForEach(CollectionsStore.symbols, id: \.self) { symbol in
                Button {
                    selection = symbol
                } label: {
                    Image(systemName: symbol)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(selection == symbol ? .white : .primary)
                        .frame(width: 38, height: 38)
                        .background(selection == symbol ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Color.primary.opacity(0.07)),
                                    in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
}

struct HistoryCard: View {
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
            .overlay(alignment: .bottomTrailing) {
                if entry.favorite {
                    Image(systemName: "heart.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.pink)
                        .padding(6)
                        .background(.ultraThinMaterial, in: Circle())
                        .padding(8)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            // Thumbnails are scaled to fill and spill past the card; keep taps inside the card.
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
    }
}

struct HistoryDetail: View {
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

// MARK: - Grids, folders and account pages

struct AccountGroup: Identifiable, Hashable {
    let id: String
    let name: String
    let platform: Platform
    let entries: [HistoryEntry]

    var itemCount: Int { entries.reduce(0) { $0 + $1.itemCount } }
}

/// A folder tile: a 2×2 mosaic of the account's latest saves.
struct AccountFolderCard: View {
    let group: AccountGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    let thumbs = Array(group.entries.prefix(4))
                    Grid(horizontalSpacing: 3, verticalSpacing: 3) {
                        GridRow {
                            tile(thumbs, 0)
                            tile(thumbs, 1)
                        }
                        GridRow {
                            tile(thumbs, 2)
                            tile(thumbs, 3)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(alignment: .topLeading) {
                    PlatformBadge(platform: group.platform, compact: true)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(8)
                }
                .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
            VStack(alignment: .leading, spacing: 1) {
                Text(group.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("\(group.entries.count) save\(group.entries.count == 1 ? "" : "s") · \(group.itemCount) item\(group.itemCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
    }

    @ViewBuilder
    private func tile(_ thumbs: [HistoryEntry], _ index: Int) -> some View {
        Group {
            if thumbs.indices.contains(index) {
                LocalImage(url: thumbs[index].thumbnailURL)
            } else {
                Color.primary.opacity(0.05)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .allowsHitTesting(false)
    }
}

/// Everything saved from one account, like an album.
struct AccountDetailView: View {
    let group: AccountGroup
    var onDetails: (HistoryEntry) -> Void

    @EnvironmentObject private var history: HistoryStore

    /// Live entries (so favourites and removals show immediately).
    private var entries: [HistoryEntry] {
        let ids = Set(group.entries.map(\.id))
        return history.entries.filter { ids.contains($0.id) }
    }

    var body: some View {
        ScrollView {
            HStack(spacing: 10) {
                PlatformBadge(platform: group.platform)
                Text("\(entries.count) save\(entries.count == 1 ? "" : "s")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            SavesGrid(entries: entries, onDetails: onDetails)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
