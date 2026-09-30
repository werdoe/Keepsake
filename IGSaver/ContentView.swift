import SwiftUI
import AVKit

struct ContentView: View {
    @StateObject private var model = DownloaderModel()
    @State private var showLogin = false
    @State private var preview: MediaItem?
    @Environment(\.scenePhase) private var scenePhase

    private let columns = [GridItem(.adaptive(minimum: 105), spacing: 8)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    inputCard
                    if model.isLoading {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Fetching…").foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    }
                    if let error = model.errorMessage {
                        errorCard(error)
                    }
                    if let result = model.result {
                        resultSection(result)
                    } else if !model.isLoading && model.errorMessage == nil {
                        tips
                    }
                }
                .padding()
            }
            .navigationTitle("IGSaver")
            .toolbar { accountMenu }
            .sheet(isPresented: $showLogin) {
                LoginView {
                    Task { await model.refreshLoginState() }
                }
            }
            .sheet(item: $preview) { item in
                PreviewSheet(item: item, model: model)
            }
            .task { await model.refreshLoginState() }
            .onChange(of: scenePhase) { phase in
                if phase == .active { Task { await model.refreshLoginState() } }
            }
        }
    }

    // MARK: - Input

    private var inputCard: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("Paste a post, reel or story link", text: $model.linkText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .onSubmit { model.fetch() }
                if !model.linkText.isEmpty {
                    Button { model.clear() } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear")
                }
            }
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))

            HStack(spacing: 10) {
                PasteButton(payloadType: String.self) { strings in
                    guard let text = strings.first else { return }
                    Task { @MainActor in model.paste(text) }
                }
                .buttonBorderShape(.capsule)
                .labelStyle(.titleAndIcon)

                Button {
                    model.fetch()
                } label: {
                    Label("Get media", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .disabled(model.linkText.isEmpty || model.isLoading)
            }
        }
    }

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 8) {
                Text(message).font(.callout)
                if !model.isLoggedIn && (message == IGError.loginRequired.errorDescription || message == IGError.checkpoint.errorDescription) {
                    Button("Log in") { showLogin = true }
                        .buttonStyle(.bordered)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    private var tips: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How to use").font(.headline)
            Label("In Instagram, tap Share (paper plane) › Copy link.", systemImage: "link")
            Label("Come back here and tap Paste.", systemImage: "doc.on.clipboard")
            Label("Save one item, or everything at once.", systemImage: "square.and.arrow.down")
            if !model.isLoggedIn {
                Divider()
                Label("Stories and highlights need you to log in first (person icon, top right).", systemImage: "person.crop.circle.badge.exclamationmark")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Results

    private func resultSection(_ result: FetchResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.title).font(.headline)
                    Text(summary(result.items)).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
            }

            Button {
                Task { await model.saveAll() }
            } label: {
                HStack {
                    if model.isSavingAll { ProgressView().tint(.white) }
                    Text(saveAllTitle(result.items))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isSavingAll || model.savedCount == result.items.count)

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(result.items) { item in
                    MediaTile(item: item, state: model.saveStates[item.id])
                        .onTapGesture { preview = item }
                        .contextMenu {
                            Button {
                                Task { await model.save(item) }
                            } label: {
                                Label("Save to Photos", systemImage: "square.and.arrow.down")
                            }
                        }
                }
            }
            Text("Tap an item to preview or save it on its own.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func summary(_ items: [MediaItem]) -> String {
        let photos = items.filter { $0.kind == .photo }.count
        let videos = items.count - photos
        var parts: [String] = []
        if photos > 0 { parts.append("\(photos) photo\(photos == 1 ? "" : "s")") }
        if videos > 0 { parts.append("\(videos) video\(videos == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    private func saveAllTitle(_ items: [MediaItem]) -> String {
        if model.savedCount == items.count { return "All saved to Photos" }
        if model.isSavingAll { return "Saving \(model.savedCount + 1) of \(items.count)…" }
        return items.count == 1 ? "Save to Photos" : "Save all \(items.count) to Photos"
    }

    // MARK: - Account

    @ToolbarContentBuilder
    private var accountMenu: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if model.isLoggedIn {
                Menu {
                    Text("Logged in to Instagram")
                    Button(role: .destructive) {
                        Task { await model.logOut() }
                    } label: {
                        Label("Log out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } label: {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                }
            } else {
                Button { showLogin = true } label: {
                    Image(systemName: "person.crop.circle")
                }
                .accessibilityLabel("Log in to Instagram")
            }
        }
    }
}

// MARK: - Tile

private struct MediaTile: View {
    let item: MediaItem
    let state: DownloaderModel.SaveState?

    var body: some View {
        Color(.secondarySystemBackground)
            .aspectRatio(aspect, contentMode: .fit)
            .overlay {
                AsyncImage(url: item.thumbnailURL) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFill()
                    case .failure: Image(systemName: "photo").foregroundStyle(.secondary)
                    default: ProgressView()
                    }
                }
            }
            .clipped()
            .overlay(alignment: .topLeading) {
                if item.kind == .video {
                    Image(systemName: "play.fill")
                        .font(.caption)
                        .padding(6)
                        .background(.ultraThinMaterial, in: Circle())
                        .padding(6)
                }
            }
            .overlay(alignment: .bottomTrailing) { badge.padding(6) }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
    }

    /// Grid tiles are portrait-ish; clamp so very tall or wide media still line up nicely.
    private var aspect: CGFloat {
        guard item.width > 0, item.height > 0 else { return 4.0 / 5.0 }
        return min(max(CGFloat(item.width) / CGFloat(item.height), 0.56), 1.0)
    }

    @ViewBuilder private var badge: some View {
        switch state {
        case .saving:
            ProgressView().padding(6).background(.ultraThinMaterial, in: Circle())
        case .saved:
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.white, .green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.white, .red)
        case .none:
            EmptyView()
        }
    }
}

// MARK: - Preview

private struct PreviewSheet: View {
    let item: MediaItem
    @ObservedObject var model: DownloaderModel
    @Environment(\.dismiss) var dismiss
    @State var player: AVPlayer?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Group {
                    if item.kind == .video {
                        VideoPlayer(player: player)
                            .onAppear {
                                let p = AVPlayer(url: item.url)
                                player = p
                                p.play()
                            }
                            .onDisappear { player?.pause() }
                    } else {
                        AsyncImage(url: item.url) { phase in
                            switch phase {
                            case .success(let image): image.resizable().scaledToFit()
                            case .failure: Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary)
                            default: ProgressView()
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if case .failed(let message) = model.saveStates[item.id] {
                    Text(message).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                }

                Button {
                    Task { await model.save(item) }
                } label: {
                    HStack {
                        if case .saving = model.saveStates[item.id] { ProgressView().tint(.white) }
                        Text(buttonTitle)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSavingOrSaved)
            }
            .padding()
            .navigationTitle(item.kind == .video ? "Video" : "Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var buttonTitle: String {
        switch model.saveStates[item.id] {
        case .saving: return "Saving…"
        case .saved: return "Saved to Photos"
        case .failed: return "Try again"
        case .none: return "Save to Photos"
        }
    }

    private var isSavingOrSaved: Bool {
        switch model.saveStates[item.id] {
        case .saving, .saved: return true
        default: return false
        }
    }
}
