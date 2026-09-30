import AVKit
import SwiftUI

/// Full-screen, swipeable preview of a bundle's items with per-item saving.
struct MediaViewer: View {
    let bundle: MediaBundle
    let startIndex: Int

    @EnvironmentObject private var model: SaveModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var dragOffset: CGFloat = 0
    @State private var chromeVisible = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
                .opacity(1 - min(abs(dragOffset) / 400, 0.6))

            TabView(selection: $index) {
                ForEach(Array(bundle.items.enumerated()), id: \.element.id) { i, item in
                    ViewerPage(item: item, isActive: i == index, quality: settings.quality)
                        .tag(i)
                        .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { chromeVisible.toggle() } }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .offset(y: dragOffset)
            .gesture(
                DragGesture(minimumDistance: 20)
                    .onChanged { value in
                        if abs(value.translation.height) > abs(value.translation.width) {
                            dragOffset = value.translation.height
                        }
                    }
                    .onEnded { value in
                        if abs(value.translation.height) > 140 {
                            dismiss()
                        } else {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { dragOffset = 0 }
                        }
                    }
            )

            if chromeVisible {
                VStack {
                    topBar
                    Spacer()
                    bottomBar
                }
                .transition(.opacity)
            }
        }
        .statusBarHidden(!chromeVisible)
        .onAppear { index = startIndex }
        .sensoryFeedback(.selection, trigger: index) { _, _ in settings.haptics }
    }

    private var currentItem: MediaItem? {
        bundle.items.indices.contains(index) ? bundle.items[index] : nil
    }

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Close")
            Spacer()
            if bundle.items.count > 1 {
                Text("\(index + 1) of \(bundle.items.count)")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
                    .contentTransition(.numericText())
                    .animation(.snappy, value: index)
            }
            Spacer()
            if let item = currentItem {
                ShareLink(item: item.standard.url) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(.ultraThinMaterial, in: Circle())
                }
            } else {
                Color.clear.frame(width: 38, height: 38)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var bottomBar: some View {
        if let item = currentItem {
            let state = model.itemStates[item.id] ?? .waiting
            VStack(spacing: 12) {
                if bundle.items.count > 1 {
                    HStack(spacing: 6) {
                        ForEach(bundle.items.indices, id: \.self) { i in
                            Capsule()
                                .fill(.white.opacity(i == index ? 1 : 0.35))
                                .frame(width: i == index ? 18 : 6, height: 6)
                        }
                    }
                    .animation(.snappy, value: index)
                }
                HStack(spacing: 10) {
                    let source = item.source(for: settings.quality)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.kind == .video ? "Video" : "Photo").font(.subheadline.weight(.semibold))
                        if source.width > 0 {
                            Text("\(source.width) × \(source.height)" + (source.audioURL != nil ? " · Best quality" : ""))
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    .foregroundStyle(.white)
                    Spacer()
                    Button {
                        model.save(item)
                    } label: {
                        HStack(spacing: 8) {
                            switch state {
                            case .downloading(let fraction):
                                ProgressRing(progress: fraction, lineWidth: 3).frame(width: 18, height: 18)
                                Text("Saving")
                            case .saved:
                                Image(systemName: "checkmark")
                                Text("Saved")
                            case .failed:
                                Image(systemName: "arrow.clockwise")
                                Text("Retry")
                            case .waiting:
                                Image(systemName: "arrow.down")
                                Text("Save")
                            }
                        }
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .frame(height: 46)
                        .background(state == .saved ? AnyShapeStyle(Color.green) : AnyShapeStyle(Brand.gradient),
                                    in: Capsule())
                    }
                    .buttonStyle(PressableStyle())
                    .disabled(state == .saved || model.phase == .saving)
                    .animation(.snappy, value: state)
                }
            }
            .padding(16)
            .background(.ultraThinMaterial.opacity(0.9), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }
}

private struct ViewerPage: View {
    let item: MediaItem
    let isActive: Bool
    let quality: QualityPreference

    @State private var player: AVPlayer?
    @State private var scale: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        Group {
            switch item.kind {
            case .photo:
                RemoteImage(url: item.standard.url, contentMode: .fit)
                    .scaleEffect(scale * pinch)
                    .gesture(
                        MagnifyGesture()
                            .updating($pinch) { value, state, _ in state = value.magnification }
                            .onEnded { value in
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                    scale = min(max(scale * value.magnification, 1), 4)
                                }
                            }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { scale = scale > 1 ? 1 : 2.5 }
                    }
            case .video:
                VideoPlayer(player: player)
                    .onAppear { preparePlayer() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: isActive) { _, active in
            if active { player?.play() } else { player?.pause() }
        }
        .onDisappear { player?.pause() }
    }

    private func preparePlayer() {
        guard player == nil else { return }
        // Preview the always-playable file; saving still uses the chosen quality.
        let p = AVPlayer(url: item.standard.url)
        player = p
        if isActive { p.play() }
    }
}
