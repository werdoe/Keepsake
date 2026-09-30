import SwiftUI

@MainActor
final class ShareModel: ObservableObject {
    enum Phase: Equatable { case finding, ready, saving, done, failed }

    @Published var phase: Phase = .finding
    @Published var bundle: MediaBundle?
    @Published var progress: SaveProgress?
    @Published var savedIDs: Set<UUID> = []
    @Published var message = ""
    @Published var successTick = 0

    var close: () -> Void = {}
    let settings = AppSettings.shared
    private var task: Task<Void, Never>?

    func start(with text: String?) {
        guard let text else {
            fail(KeepsakeError.unsupportedLink)
            return
        }
        task = Task {
            do {
                let result = try await MediaFetcher.fetch(text)
                withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                    bundle = result
                    phase = .ready
                }
                if settings.shareAutoSave { save() }
            } catch {
                fail(error)
            }
        }
    }

    func save() {
        guard let bundle, phase != .saving else { return }
        withAnimation(.snappy) { phase = .saving }
        task = Task {
            do {
                let result = try await SavePipeline.save(
                    bundle.items, from: bundle,
                    onItemSaved: { [weak self] id in
                        Task { @MainActor in withAnimation(.spring) { _ = self?.savedIDs.insert(id) } }
                    },
                    progress: { [weak self] p in
                        Task { @MainActor in self?.progress = p }
                    })
                message = result.failures.isEmpty
                    ? (result.savedItemIDs.count == 1 ? "Saved to Photos" : "Saved \(result.savedItemIDs.count) items to Photos")
                    : "Saved \(result.savedItemIDs.count) of \(bundle.items.count)"
                withAnimation(.spring(response: 0.45, dampingFraction: 0.6)) { phase = .done }
                successTick += 1
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                close()
            } catch is CancellationError {
                close()
            } catch {
                fail(error)
            }
        }
    }

    func cancel() {
        task?.cancel()
        close()
    }

    private func fail(_ error: Error) {
        message = KeepsakeError.from(error).localizedDescription
        withAnimation(.snappy) { phase = .failed }
    }
}

/// Compact card shown over the app you shared from.
struct ShareCardView: View {
    @ObservedObject var model: ShareModel

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture { if model.phase != .saving { model.cancel() } }

            VStack(spacing: 18) {
                header
                content
            }
            .padding(20)
            .frame(maxWidth: 500)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).strokeBorder(.white.opacity(0.15)))
            .shadow(color: .black.opacity(0.2), radius: 30, y: 10)
            .padding(12)
            .transition(.move(edge: .bottom))
        }
        .sensoryFeedback(.success, trigger: model.successTick) { _, _ in model.settings.haptics }
    }

    private var header: some View {
        HStack(spacing: 12) {
            KeepsakeMark(size: 36, fanned: model.phase == .saving)
                .animation(.spring(response: 0.5, dampingFraction: 0.6), value: model.phase)
            VStack(alignment: .leading, spacing: 1) {
                Text(Brand.name).font(.headline)
                Text(model.bundle.map { "\($0.platform.name) · \($0.title)" } ?? "Save to Photos")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                model.cancel()
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(Color.primary.opacity(0.08), in: Circle())
            }
            .accessibilityLabel("Close")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .finding:
            VStack(spacing: 12) {
                thumbnailStrip(placeholder: true)
                Label("Finding media…", systemImage: "magnifyingglass")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .symbolEffect(.pulse, options: .repeating)
            }
        case .ready:
            VStack(spacing: 14) {
                thumbnailStrip(placeholder: false)
                Button {
                    model.save()
                } label: {
                    Label(model.bundle?.items.count == 1 ? "Save to Photos" : "Save All \(model.bundle?.items.count ?? 0)",
                          systemImage: "arrow.down.circle.fill")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Brand.gradient, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                }
            }
        case .saving:
            VStack(spacing: 12) {
                thumbnailStrip(placeholder: false)
                HStack {
                    Text(model.progress?.message ?? "Starting…")
                        .font(.subheadline.weight(.medium))
                        .contentTransition(.numericText())
                    Spacer()
                    Text("\(Int((model.progress?.fraction ?? 0) * 100))%")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                ProgressView(value: model.progress?.fraction ?? 0)
                    .tint(Brand.blue)
                    .animation(.easeOut, value: model.progress?.fraction ?? 0)
            }
        case .done:
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .green)
                    .symbolEffect(.bounce, value: model.successTick)
                    .transition(.scale.combined(with: .opacity))
                Text(model.message).font(.headline)
            }
            .padding(.vertical, 8)
        case .failed:
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.orange)
                Text(model.message)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("Close") { model.cancel() }
                    .buttonStyle(.bordered)
            }
        }
    }

    private func thumbnailStrip(placeholder: Bool) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if placeholder || model.bundle == nil {
                    ForEach(0..<4, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                            .frame(width: 70, height: 88)
                    }
                } else if let bundle = model.bundle {
                    ForEach(bundle.items) { item in
                        AsyncImage(url: item.thumbnailURL) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Color.primary.opacity(0.08)
                        }
                        .frame(width: 70, height: 88)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(alignment: .bottomTrailing) {
                            if model.savedIDs.contains(item.id) {
                                Image(systemName: "checkmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .green)
                                    .padding(4)
                                    .transition(.scale.combined(with: .opacity))
                            } else if item.kind == .video {
                                Image(systemName: "play.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.white)
                                    .padding(5)
                                    .background(.black.opacity(0.35), in: Circle())
                                    .padding(4)
                            }
                        }
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                }
            }
        }
        .frame(height: 88)
    }
}
