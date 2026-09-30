import AVKit
import Photos
import SwiftUI

/// Where a saved item lives.
enum SavedMediaRef: Hashable {
    case asset(String)
    case file(URL)
    /// Nothing saved we can reach (e.g. deleted from Photos); show the Library thumbnail.
    case thumbnail(URL?)
}

/// One swipeable page: a single photo or video from a Library entry.
struct LibraryPage: Identifiable, Hashable {
    let id: String
    let entry: HistoryEntry
    let ref: SavedMediaRef
    let indexInEntry: Int
    let countInEntry: Int

    static func pages(for entries: [HistoryEntry]) -> [LibraryPage] {
        entries.flatMap { entry -> [LibraryPage] in
            var refs: [SavedMediaRef] = entry.assetIdentifiers.map { .asset($0) }
            if refs.isEmpty { refs = entry.fileURLs.map { .file($0) } }
            if refs.isEmpty { refs = [.thumbnail(entry.thumbnailURL)] }
            return refs.enumerated().map { index, ref in
                LibraryPage(id: "\(entry.id)-\(index)", entry: entry, ref: ref, indexInEntry: index, countInEntry: refs.count)
            }
        }
    }
}

struct ViewerStart: Identifiable {
    let id = UUID()
    let entries: [HistoryEntry]
    let startEntryID: UUID
}

/// Full-screen, swipeable viewer for everything in (part of) the Library.
struct LibraryViewer: View {
    let start: ViewerStart

    @EnvironmentObject private var history: HistoryStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var pages: [LibraryPage] = []
    @State private var position = 0
    @State private var chromeVisible = true
    @State private var dragOffset: CGFloat = 0
    @State private var photosAccess = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var shareItem: ShareItem?
    @State private var preparingShare = false
    @State private var confirmDelete = false
    @State private var detailEntry: HistoryEntry?
    @State private var toast: String?
    @State private var feedbackTick = 0

    private var current: LibraryPage? { pages.indices.contains(position) ? pages[position] : nil }

    private var liveEntry: HistoryEntry? {
        guard let current else { return nil }
        return history.entries.first { $0.id == current.entry.id } ?? current.entry
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea().opacity(backgroundOpacity)

            TabView(selection: $position) {
                ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                    SavedMediaView(ref: page.ref, fallback: page.entry.thumbnailURL, isActive: index == position)
                        .tag(index)
                        .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { chromeVisible.toggle() } }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .offset(y: dragOffset)
            .simultaneousGesture(dismissDrag)

            if chromeVisible {
                VStack(spacing: 0) {
                    topBar
                    if needsPhotosAccess { accessBanner }
                    Spacer()
                    bottomBar
                }
                .transition(.opacity)
            }

            if let toast {
                Text(toast)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .statusBarHidden(!chromeVisible)
        .onAppear(perform: setUp)
        .sheet(item: $shareItem) { item in ShareSheet(items: item.items) }
        .sheet(item: $detailEntry) { entry in
            HistoryDetail(entry: entry) { detailEntry = nil }
                .presentationDetents([.medium, .large])
        }
        .confirmationDialog("Delete this save?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Remove from Keepsake Library", role: .destructive) { removeCurrent(deleteFromPhotos: false) }
            if let entry = current?.entry, !entry.assetIdentifiers.isEmpty {
                Button("Delete from Photos too", role: .destructive) { removeCurrent(deleteFromPhotos: true) }
            }
        } message: {
            Text("This removes the whole post (\(current?.countInEntry ?? 1) item\((current?.countInEntry ?? 1) == 1 ? "" : "s")).")
        }
        .sensoryFeedback(.selection, trigger: position) { _, _ in settings.haptics }
        .sensoryFeedback(.impact(weight: .light), trigger: feedbackTick) { _, _ in settings.haptics }
    }

    // MARK: - Setup

    private func setUp() {
        pages = LibraryPage.pages(for: start.entries)
        position = pages.firstIndex { $0.entry.id == start.startEntryID } ?? 0
        if photosAccess == .notDetermined, pages.contains(where: { if case .asset = $0.ref { return true } else { return false } }) {
            Task {
                let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                await MainActor.run { photosAccess = status }
            }
        }
    }

    private var needsPhotosAccess: Bool {
        guard case .asset = current?.ref else { return false }
        return photosAccess == .denied || photosAccess == .restricted
    }

    private var backgroundOpacity: Double {
        let fade: CGFloat = min(abs(dragOffset) / CGFloat(400), CGFloat(0.6))
        return Double(1 - fade)
    }

    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 24)
            .onChanged { value in
                if abs(value.translation.height) > abs(value.translation.width) * 1.4 {
                    dragOffset = value.translation.height
                }
            }
            .onEnded { value in
                if abs(dragOffset) > 140 {
                    dismiss()
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { dragOffset = 0 }
                }
            }
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack(spacing: 10) {
            circleButton("xmark", label: "Close") { dismiss() }
            Spacer()
            if let current {
                VStack(spacing: 1) {
                    Text(current.entry.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(current.countInEntry > 1
                         ? "\(current.indexInEntry + 1) of \(current.countInEntry) · \(current.entry.date.formatted(.relative(presentation: .named)))"
                         : current.entry.date.formatted(.relative(presentation: .named)))
                        .font(.caption2.monospacedDigit())
                        .opacity(0.75)
                        .contentTransition(.numericText())
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .animation(.snappy, value: position)
            }
            Spacer()
            if let entry = liveEntry {
                circleButton(entry.favorite ? "heart.fill" : "heart", label: "Favourite",
                             tint: entry.favorite ? .pink : .white) {
                    history.toggleFavorite(entry)
                    feedbackTick += 1
                }
                .symbolEffect(.bounce, value: entry.favorite)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var accessBanner: some View {
        Button {
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        } label: {
            Label("Allow access to Photos to view your saves full size", systemImage: "photo.badge.exclamationmark")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .padding(10)
                .background(.orange.opacity(0.85), in: Capsule())
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var bottomBar: some View {
        if let current {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    PlatformBadge(platform: current.entry.platform)
                        .background(.ultraThinMaterial, in: Capsule())
                    if let q = current.entry.qualityLabel { QualityPill(text: q) }
                    Spacer()
                    Text("\(position + 1) / \(pages.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
                }
                if let caption = current.entry.caption {
                    Text(caption)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(3)
                        .onLongPressGesture { copy(caption, "Caption copied") }
                }
                HStack(spacing: 0) {
                    action("square.and.arrow.up", preparingShare ? "Preparing…" : "Share") { share(current) }
                    action("safari", "Original") { openURL(current.entry.sourceURL) }
                    if let caption = current.entry.caption {
                        action("text.quote", "Caption") { copy(caption, "Caption copied") }
                    } else {
                        action("link", "Link") { copy(current.entry.sourceURL.absoluteString, "Link copied") }
                    }
                    action("info.circle", "Details") { detailEntry = liveEntry }
                    action("trash", "Delete", tint: .red) { confirmDelete = true }
                }
            }
            .padding(16)
            .background(
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            )
        }
    }

    private func circleButton(_ symbol: String, label: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel(label)
    }

    private func action(_ symbol: String, _ title: String, tint: Color = .white, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.title3)
                Text(title).font(.caption2.weight(.medium))
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PressableStyle())
    }

    // MARK: - Actions

    private func copy(_ text: String, _ message: String) {
        UIPasteboard.general.string = text
        feedbackTick += 1
        show(message)
    }

    private func show(_ message: String) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { toast = message }
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            await MainActor.run { withAnimation { toast = nil } }
        }
    }

    private func share(_ page: LibraryPage) {
        guard !preparingShare else { return }
        preparingShare = true
        Task {
            let items = await SavedMediaExporter.shareItems(for: page.ref, fallback: page.entry.sourceURL)
            await MainActor.run {
                preparingShare = false
                shareItem = ShareItem(items: items)
            }
        }
    }

    private func removeCurrent(deleteFromPhotos: Bool) {
        guard let current else { return }
        let entry = current.entry
        Task {
            if deleteFromPhotos {
                let assets = PHAsset.fetchAssets(withLocalIdentifiers: entry.assetIdentifiers, options: nil)
                // iOS shows its own confirmation for deleting from Photos.
                try? await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.deleteAssets(assets)
                }
            }
            await MainActor.run {
                history.remove(entry)
                let remaining = pages.filter { $0.entry.id != entry.id }
                if remaining.isEmpty {
                    dismiss()
                } else {
                    let firstIndex = pages.firstIndex { $0.entry.id == entry.id } ?? 0
                    withAnimation(.snappy) {
                        pages = remaining
                        position = min(firstIndex, remaining.count - 1)
                    }
                    show(deleteFromPhotos ? "Deleted" : "Removed from Library")
                }
            }
        }
    }
}

// MARK: - One page

/// Shows a saved photo (zoomable) or video from Photos or Files.
struct SavedMediaView: View {
    let ref: SavedMediaRef
    let fallback: URL?
    let isActive: Bool

    @StateObject private var loader = SavedMediaLoader()
    @State private var scale: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let player = loader.player {
                    VideoPlayer(player: player)
                        .onAppear { if isActive { player.play() } }
                } else if let image = loader.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale * pinch)
                        .gesture(
                            MagnifyGesture()
                                .updating($pinch) { value, state, _ in state = value.magnification }
                                .onEnded { value in
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                        scale = min(max(scale * value.magnification, 1), 5)
                                    }
                                }
                        )
                        .onTapGesture(count: 2) {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { scale = scale > 1 ? 1 : 2.5 }
                        }
                } else {
                    ProgressView().tint(.white)
                }
                if loader.unavailable {
                    VStack {
                        Spacer()
                        Label("Not in Photos any more. Showing the preview.", systemImage: "exclamationmark.triangle")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(.black.opacity(0.5), in: Capsule())
                            .padding(.bottom, 170)
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .onAppear {
                let screenScale = UIScreen.main.scale
                loader.load(ref, fallback: fallback,
                            size: CGSize(width: proxy.size.width * screenScale, height: proxy.size.height * screenScale))
            }
        }
        .onChange(of: isActive) { _, active in
            if active { loader.player?.play() } else { loader.player?.pause(); scale = 1 }
        }
        .onDisappear { loader.player?.pause() }
    }
}

@MainActor
final class SavedMediaLoader: ObservableObject {
    @Published var image: UIImage?
    @Published var player: AVPlayer?
    @Published var unavailable = false
    private var loaded = false

    func load(_ ref: SavedMediaRef, fallback: URL?, size: CGSize) {
        guard !loaded else { return }
        loaded = true
        switch ref {
        case .asset(let id):
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
                showFallback(fallback)
                return
            }
            let imageOptions = PHImageRequestOptions()
            imageOptions.isNetworkAccessAllowed = true
            imageOptions.deliveryMode = .opportunistic
            PHImageManager.default().requestImage(for: asset, targetSize: size, contentMode: .aspectFit, options: imageOptions) { [weak self] image, _ in
                guard let image else { return }
                DispatchQueue.main.async { self?.image = image }
            }
            if asset.mediaType == .video {
                let videoOptions = PHVideoRequestOptions()
                videoOptions.isNetworkAccessAllowed = true
                videoOptions.deliveryMode = .automatic
                PHImageManager.default().requestPlayerItem(forVideo: asset, options: videoOptions) { [weak self] item, _ in
                    guard let item else { return }
                    DispatchQueue.main.async { self?.player = AVPlayer(playerItem: item) }
                }
            }
        case .file(let url):
            if ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) {
                player = AVPlayer(url: url)
            } else if let image = UIImage(contentsOfFile: url.path) {
                self.image = image
            } else {
                showFallback(fallback)
            }
        case .thumbnail(let url):
            showFallback(url ?? fallback)
        }
    }

    private func showFallback(_ url: URL?) {
        unavailable = true
        if let url, let image = UIImage(contentsOfFile: url.path) { self.image = image }
    }
}

// MARK: - Sharing the actual file

struct ShareItem: Identifiable {
    let id = UUID()
    let items: [Any]
}

enum SavedMediaExporter {
    /// A file to share: the original from Photos, the file in Files, or the post link as a fallback.
    static func shareItems(for ref: SavedMediaRef, fallback: URL) async -> [Any] {
        switch ref {
        case .file(let url):
            return [url]
        case .thumbnail:
            return [fallback]
        case .asset(let id):
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return [fallback] }
            let resources = PHAssetResource.assetResources(for: asset)
            let preferred: [PHAssetResourceType] = asset.mediaType == .video ? [.fullSizeVideo, .video] : [.fullSizePhoto, .photo]
            guard let resource = preferred.lazy.compactMap({ type in resources.first { $0.type == type } }).first
                    ?? resources.first else { return [fallback] }
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let file = destination.appendingPathComponent(resource.originalFilename)
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            do {
                try await PHAssetResourceManager.default().writeData(for: resource, toFile: file, options: options)
                return [file]
            } catch {
                return [fallback]
            }
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
