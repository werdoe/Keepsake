import SwiftUI

// MARK: - Animated background

/// Slowly drifting colour blobs behind the content. Static when Reduce Motion is on.
struct AuroraBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    var intensity: Double = 1

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
            let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                context.addFilter(.blur(radius: min(size.width, size.height) * 0.16))
                let blobs: [(Color, Double, Double, Double)] = [
                    (Brand.teal, 0.18, 0.12, 0.00),
                    (Brand.blue, 0.82, 0.22, 2.10),
                    (Brand.indigo, 0.45, 0.55, 4.20),
                ]
                for (color, bx, by, phase) in blobs {
                    let x = size.width * (bx + 0.10 * sin(t * 0.21 + phase))
                    let y = size.height * (by + 0.06 * cos(t * 0.17 + phase))
                    let r = min(size.width, size.height) * 0.42
                    let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                    let opacity = (colorScheme == .dark ? 0.42 : 0.30) * intensity
                    context.fill(Path(ellipseIn: rect), with: .color(color.opacity(opacity)))
                }
            }
        }
        .ignoresSafeArea()
        .background(Color(.systemGroupedBackground))
    }
}

// MARK: - Cards & badges

struct GlassCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.06), radius: 18, y: 8)
    }
}

struct PlatformBadge: View {
    let platform: Platform
    var compact = false

    var body: some View {
        Label(platform.name, systemImage: platform.symbol)
            .labelStyle(compact ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
            .font(.caption.weight(.semibold))
            .foregroundStyle(platform.tint)
            .padding(.horizontal, compact ? 7 : 10)
            .padding(.vertical, 5)
            .background(platform.tint.opacity(0.12), in: Capsule())
    }
}

/// Type-erased label style so a badge can switch styles.
struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView
    init<S: LabelStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

struct QualityPill: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Brand.gradient, in: Capsule())
    }
}

// MARK: - Progress

struct ProgressRing: View {
    var progress: Double
    var lineWidth: CGFloat = 4

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.25), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.02, min(progress, 1)))
                .stroke(.white, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.25), value: progress)
        }
    }
}

struct GradientProgressBar: View {
    var progress: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(Brand.gradient)
                    .frame(width: max(8, proxy.size.width * min(max(progress, 0), 1)))
                    .animation(.easeOut(duration: 0.3), value: progress)
            }
        }
        .frame(height: 8)
    }
}

// MARK: - Buttons

struct GradientButtonStyle: ButtonStyle {
    var height: CGFloat = 54

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(Brand.gradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: Brand.blue.opacity(configuration.isPressed ? 0.15 : 0.35), radius: 14, y: 6)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Loading skeleton

struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { proxy in
                    LinearGradient(colors: [.clear, .white.opacity(0.35), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: proxy.size.width * 0.6)
                        .offset(x: phase * proxy.size.width * 1.6)
                }
                .mask(content)
                .allowsHitTesting(false)
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }
}

extension View {
    func shimmering() -> some View { modifier(ShimmerModifier()) }
}

struct SkeletonGrid: View {
    var count = 6
    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 10)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(0..<count, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
                    .aspectRatio(0.8, contentMode: .fit)
                    .shimmering()
            }
        }
    }
}

// MARK: - Remote image

/// AsyncImage with a soft placeholder and fade-in.
struct RemoteImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.25))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: contentMode).transition(.opacity)
            case .failure:
                ZStack {
                    Color.primary.opacity(0.06)
                    Image(systemName: "photo").foregroundStyle(.tertiary)
                }
            default:
                Color.primary.opacity(0.06).shimmering()
            }
        }
    }
}

/// Local thumbnail file (Library).
struct LocalImage: View {
    let url: URL?

    var body: some View {
        if let url, let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            ZStack {
                Brand.softGradient
                KeepsakeMark(size: 36).opacity(0.5)
            }
        }
    }
}
