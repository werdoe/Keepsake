import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var model: SaveModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var history: HistoryStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Binding var selectedTab: RootView.Tab
    @Binding var loginPlatform: Platform?

    @State private var viewerIndex: ViewerSelection?
    @State private var showBatch = false
    @FocusState private var fieldFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 10)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    inputCard
                    if model.clipboardHasLink && model.phase == .idle && model.linkText.isEmpty {
                        clipboardBanner.transition(.move(edge: .top).combined(with: .opacity))
                    }
                    content
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 120)
            }
            .scrollDismissesKeyboard(.interactively)
            .background { AuroraBackground() }
            .safeAreaInset(edge: .bottom) { bottomBar }
            .toolbar(.hidden, for: .navigationBar)
            .overlay(alignment: .bottom) { toastView }
            .sheet(isPresented: $showBatch) { BatchView() }
            .fullScreenCover(item: $viewerIndex) { selection in
                if let bundle = model.bundle {
                    MediaViewer(bundle: bundle, startIndex: selection.index)
                        .environmentObject(model)
                }
            }
        }
        .onAppear { model.checkClipboard() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.checkClipboard() }
        }
        .sensoryFeedback(.success, trigger: model.successTick) { _, _ in settings.haptics }
        .sensoryFeedback(.error, trigger: model.errorTick) { _, _ in settings.haptics }
        .sensoryFeedback(.impact(weight: .light), trigger: model.lightTick) { _, _ in settings.haptics }
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast = model.toast {
            Text(toast)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
                .padding(.bottom, model.bundle == nil ? 24 : 110)
                .padding(.horizontal, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            KeepsakeMark(size: 46, fanned: model.phase == .saving)
                .animation(.spring(response: 0.5, dampingFraction: 0.6), value: model.phase)
            VStack(alignment: .leading, spacing: 2) {
                Text(Brand.name)
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                Text("Photos and videos in their best quality")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button {
                showBatch = true
            } label: {
                Image(systemName: "square.stack.3d.down.right.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Brand.blue)
                    .frame(width: 42, height: 42)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Batch Save")
        }
        .padding(.top, 12)
    }

    // MARK: - Input

    private var inputCard: some View {
        GlassCard {
            VStack(spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: model.detectedPlatform?.symbol ?? "link")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(model.detectedPlatform?.tint ?? .secondary)
                        .frame(width: 22)
                        .contentTransition(.symbolEffect(.replace))
                    TextField("Paste a link", text: $model.linkText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.go)
                        .focused($fieldFocused)
                        .onSubmit { model.fetch() }
                    if !model.linkText.isEmpty {
                        Button {
                            model.reset()
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear")
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 50)
                .background(Color(.systemBackground).opacity(0.7), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .animation(.snappy, value: model.linkText.isEmpty)

                HStack(spacing: 10) {
                    PasteButton(payloadType: String.self) { strings in
                        guard let text = strings.first else { return }
                        Task { @MainActor in
                            fieldFocused = false
                            model.paste(text)
                        }
                    }
                    .labelStyle(.titleAndIcon)
                    .buttonBorderShape(.roundedRectangle(radius: 14))
                    .controlSize(.large)
                    .tint(Brand.blue)

                    Button {
                        fieldFocused = false
                        model.fetch()
                    } label: {
                        Label("Get Media", systemImage: "sparkles")
                    }
                    .buttonStyle(GradientButtonStyle(height: 46))
                    .disabled(model.linkText.isEmpty || model.phase == .fetching)
                    .opacity(model.linkText.isEmpty ? 0.55 : 1)
                }

                PlatformChips()
            }
        }
    }

    private var clipboardBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.on.clipboard.fill")
                .font(.title3)
                .foregroundStyle(Brand.gradient)
                .symbolEffect(.pulse, options: .repeating)
            VStack(alignment: .leading, spacing: 2) {
                Text("Link on your clipboard").font(.subheadline.weight(.semibold))
                Text("Tap Paste to fetch it").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            PasteButton(payloadType: String.self) { strings in
                guard let text = strings.first else { return }
                Task { @MainActor in model.paste(text) }
            }
            .labelStyle(.iconOnly)
            .buttonBorderShape(.circle)
            .tint(Brand.blue)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: - Content by phase

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            howItWorks
            recentSaves
        case .fetching:
            VStack(alignment: .leading, spacing: 12) {
                Label("Finding media…", systemImage: "magnifyingglass")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .symbolEffect(.pulse, options: .repeating)
                SkeletonGrid()
            }
            .transition(.opacity)
        case .failed:
            errorCard
            howItWorks
        case .ready, .saving, .done:
            if let bundle = model.bundle {
                results(bundle)
            }
        }
    }

    private func results(_ bundle: MediaBundle) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    PlatformBadge(platform: bundle.platform)
                    Text(bundle.title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(bundle.summary).font(.subheadline).foregroundStyle(.secondary)
                        if let label = bestLabel(bundle) {
                            QualityPill(text: label)
                        }
                    }
                }
                Spacer()
            }
            if let earlier = model.previousSave, model.phase == .ready {
                duplicateBanner(earlier)
            }
            if let caption = bundle.caption {
                CaptionCard(caption: caption, hashtags: bundle.hashtags) { text, label in
                    model.copy(text, confirmation: label)
                }
            }
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(Array(bundle.items.enumerated()), id: \.element.id) { index, item in
                    Button {
                        viewerIndex = ViewerSelection(index: index)
                    } label: {
                        MediaTile(item: item, state: model.itemStates[item.id] ?? .waiting,
                                  quality: settings.quality, appearDelay: Double(index) * 0.05)
                    }
                    .buttonStyle(PressableStyle())
                    .contextMenu {
                        Button {
                            model.save(item)
                        } label: {
                            Label("Save to Photos", systemImage: "square.and.arrow.down")
                        }
                        if item.kind == .video || item.audio != nil {
                            Button {
                                model.saveAudio(item)
                            } label: {
                                Label("Save Audio", systemImage: "waveform")
                            }
                        }
                        if let caption = bundle.caption {
                            Button {
                                model.copy(caption, confirmation: "Caption copied")
                            } label: {
                                Label("Copy Caption", systemImage: "text.quote")
                            }
                        }
                        Button {
                            model.copy(bundle.sourceURL.absoluteString, confirmation: "Link copied")
                        } label: {
                            Label("Copy Link", systemImage: "link")
                        }
                    }
                }
            }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func duplicateBanner(_ earlier: HistoryEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("You saved this \(earlier.date.formatted(.relative(presentation: .named)))")
                    .font(.subheadline.weight(.semibold))
                Text("Save it again, or check your Library.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Library") { selectedTab = .library }
                .font(.subheadline.weight(.semibold))
        }
        .padding(14)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func bestLabel(_ bundle: MediaBundle) -> String? {
        bundle.items.compactMap { $0.source(for: settings.quality).resolutionLabel }.first
    }

    private var errorCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Couldn't get that one", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text(model.errorMessage ?? "Something went wrong.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Try Again") { model.fetch() }
                        .buttonStyle(.bordered)
                    if let platform = model.lastError?.needsLogin {
                        Button("Log In to \(platform.name)") { loginPlatform = platform }
                            .buttonStyle(.borderedProminent)
                            .tint(Brand.blue)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .transition(.scale(scale: 0.96).combined(with: .opacity))
    }

    private var howItWorks: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Three ways to save").font(.headline)
                step("square.and.arrow.up", "From the share sheet",
                     "In Instagram, Threads, Facebook or TikTok tap Share, then Keepsake. It saves on its own.")
                step("doc.on.clipboard", "Paste a link", "Copy a link, come back here and tap Paste.")
                step("square.grid.2x2", "Pick what you want", "Tap an item to preview it. Long-press for audio, caption and link.")
                step("square.stack.3d.down.right", "Save lots at once", "Tap the stack button to paste many links or grab several accounts' stories.")
            }
        }
    }

    private func step(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Brand.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var recentSaves: some View {
        if !history.entries.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Recent").font(.headline)
                    Spacer()
                    Button("See All") { selectedTab = .library }
                        .font(.subheadline)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(history.entries.prefix(8)) { entry in
                            LocalImage(url: entry.thumbnailURL)
                                .frame(width: 96, height: 120)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(alignment: .bottomLeading) {
                                    PlatformBadge(platform: entry.platform, compact: true)
                                        .background(.ultraThinMaterial, in: Capsule())
                                        .padding(6)
                                }
                                .onTapGesture { selectedTab = .library }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Bottom bar

    @ViewBuilder
    private var bottomBar: some View {
        if let bundle = model.bundle, model.phase != .fetching {
            VStack(spacing: 10) {
                switch model.phase {
                case .saving:
                    VStack(spacing: 8) {
                        HStack {
                            Text(model.progress?.message ?? "Starting…")
                                .font(.subheadline.weight(.medium))
                                .contentTransition(.numericText())
                            Spacer()
                            Text("\(Int((model.progress?.fraction ?? 0) * 100))%")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .contentTransition(.numericText())
                            Button {
                                model.cancelSave()
                            } label: {
                                Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
                            }
                            .accessibilityLabel("Cancel")
                        }
                        GradientProgressBar(progress: model.progress?.fraction ?? 0)
                    }
                case .done:
                    HStack(spacing: 12) {
                        Label(settings.destination == .files ? "Saved to Files" : "Saved", systemImage: "checkmark.circle.fill")
                            .font(.headline)
                            .foregroundStyle(.green)
                            .symbolEffect(.bounce, value: model.successTick)
                        Spacer()
                        Button(settings.destination == .files ? "Open Files" : "Open Photos") {
                            let scheme = settings.destination == .files ? "shareddocuments://" : "photos-redirect://"
                            if let url = URL(string: scheme) { openURL(url) }
                        }
                        .buttonStyle(.bordered)
                        Button("New") { model.reset() }
                            .buttonStyle(.borderedProminent)
                            .tint(Brand.blue)
                    }
                default:
                    Button {
                        model.saveAll()
                    } label: {
                        Label(bundle.items.count == 1 ? "Save to Photos" : "Save All \(bundle.items.count)",
                              systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(GradientButtonStyle())
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.bar)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

struct ViewerSelection: Identifiable {
    let index: Int
    var id: Int { index }
}

// MARK: - Tile

struct MediaTile: View {
    let item: MediaItem
    let state: SaveModel.ItemState
    let quality: QualityPreference
    var appearDelay: Double = 0

    @State private var appeared = false

    var body: some View {
        Color.clear
            .aspectRatio(min(max(item.aspectRatio, 0.56), 1.2), contentMode: .fit)
            .overlay { RemoteImage(url: item.thumbnailURL).allowsHitTesting(false) }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(alignment: .topLeading) {
                if item.kind == .video {
                    HStack(spacing: 3) {
                        Image(systemName: "play.fill")
                        if let label = item.source(for: quality).resolutionLabel { Text(label) }
                    }
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.35), in: Capsule())
                    .padding(6)
                }
            }
            .overlay { stateOverlay }
            .opacity(appeared ? 1 : 0)
            .scaleEffect(appeared ? 1 : 0.92)
            .onAppear {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.8).delay(appearDelay)) { appeared = true }
            }
    }

    @ViewBuilder
    private var stateOverlay: some View {
        switch state {
        case .waiting:
            EmptyView()
        case .downloading(let fraction):
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.black.opacity(0.35))
                ProgressRing(progress: fraction).frame(width: 34, height: 34)
            }
            .transition(.opacity)
        case .saved:
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.black.opacity(0.12))
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .green)
                    .padding(6)
                    .transition(.scale.combined(with: .opacity))
            }
        case .failed:
            ZStack(alignment: .bottomTrailing) {
                Color.clear
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .red)
                    .padding(6)
            }
        }
    }
}

// MARK: - Caption

/// The post's caption. Long-press (or tap Copy) to copy it; tap a hashtag chip to copy all tags.
struct CaptionCard: View {
    let caption: String
    let hashtags: [String]
    var onCopy: (String, String) -> Void

    @State private var expanded = false
    @State private var pressed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Caption", systemImage: "text.quote")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    onCopy(caption, "Caption copied")
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
            }
            Text(caption)
                .font(.subheadline)
                .lineLimit(expanded ? nil : 3)
                .textSelection(.enabled)
                .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }
            if !hashtags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Button {
                            onCopy(hashtags.joined(separator: " "), "\(hashtags.count) hashtag\(hashtags.count == 1 ? "" : "s") copied")
                        } label: {
                            Label("Copy tags", systemImage: "number")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Brand.gradient, in: Capsule())
                        }
                        ForEach(hashtags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.primary.opacity(0.06), in: Capsule())
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .scaleEffect(pressed ? 0.98 : 1)
        .onLongPressGesture(minimumDuration: 0.45, pressing: { isPressing in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { pressed = isPressing }
        }, perform: {
            onCopy(caption, "Caption copied")
        })
        .accessibilityAction(named: "Copy caption") { onCopy(caption, "Caption copied") }
    }
}
