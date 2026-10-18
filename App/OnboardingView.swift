import SwiftUI

/// First-launch welcome: three animated pages.
struct OnboardingView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var page = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let pages: [(title: String, detail: String)] = [
        ("Keep what you love.", "Save photos, reels, stories and videos from Instagram, Threads, Facebook, TikTok and Reddit, with no watermarks."),
        ("Share. Saved.", "Tap Share, then Keepsake, in any of those apps. It saves on its own, with no copying and pasting."),
        ("Best quality, your way.", "Choose the best available quality, limit downloads to Wi-Fi, and follow progress in the Dynamic Island."),
    ]

    var body: some View {
        ZStack {
            AuroraBackground(intensity: 1.4)
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    if page < pages.count - 1 {
                        Button("Skip") { finish() }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: 44)
                .padding(.horizontal, 24)

                TabView(selection: $page) {
                    ForEach(pages.indices, id: \.self) { i in
                        VStack(spacing: 28) {
                            Spacer(minLength: 0)
                            hero(for: i)
                                .frame(height: 260)
                            VStack(spacing: 12) {
                                Text(pages[i].title)
                                    .font(.system(size: 34, weight: .bold, design: .rounded))
                                    .multilineTextAlignment(.center)
                                Text(pages[i].detail)
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 12)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 28)
                        .tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                HStack(spacing: 8) {
                    ForEach(pages.indices, id: \.self) { i in
                        Capsule()
                            .fill(i == page ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Color.primary.opacity(0.2)))
                            .frame(width: i == page ? 24 : 8, height: 8)
                    }
                }
                .animation(.snappy, value: page)
                .padding(.bottom, 24)

                Button {
                    if page < pages.count - 1 {
                        withAnimation(.snappy) { page += 1 }
                    } else {
                        finish()
                    }
                } label: {
                    Text(page < pages.count - 1 ? "Continue" : "Get Started")
                        .contentTransition(.interpolate)
                }
                .buttonStyle(GradientButtonStyle())
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }
        }
        .sensoryFeedback(.selection, trigger: page)
    }

    private func finish() {
        withAnimation(.easeInOut) { settings.hasOnboarded = true }
    }

    @ViewBuilder
    private func hero(for index: Int) -> some View {
        switch index {
        case 0: CardStackHero(animate: !reduceMotion && page == 0)
        case 1: ShareHero(animate: !reduceMotion && page == 1)
        default: QualityHero(animate: !reduceMotion && page == 2)
        }
    }
}

/// Floating fan of photo cards around the mark.
private struct CardStackHero: View {
    var animate: Bool
    @State private var fanned = false

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill([Brand.teal, Brand.blue, Brand.indigo][i].gradient)
                    .frame(width: 150, height: 190)
                    .overlay {
                        Image(systemName: ["photo", "play.fill", "camera"][i])
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    .rotationEffect(.degrees(fanned ? Double(i - 1) * 16 : Double(i - 1) * 4))
                    .offset(x: fanned ? CGFloat(i - 1) * 70 : CGFloat(i - 1) * 12,
                            y: fanned ? abs(CGFloat(i - 1)) * 16 : 0)
                    .shadow(color: .black.opacity(0.15), radius: 16, y: 10)
            }
            KeepsakeMark(size: 84, monochrome: true)
                .padding(18)
                .background(Brand.gradient, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                .shadow(color: Brand.blue.opacity(0.5), radius: 20, y: 10)
                .offset(y: 80)
                .scaleEffect(fanned ? 1 : 0.85)
        }
        .onAppear { run() }
        .onChange(of: animate) { _, _ in run() }
    }

    private func run() {
        guard animate else { fanned = true; return }
        fanned = false
        withAnimation(.spring(response: 0.9, dampingFraction: 0.65).delay(0.15)) { fanned = true }
    }
}

/// A share sheet row where the Keepsake tile pops.
private struct ShareHero: View {
    var animate: Bool
    @State private var pop = false
    @State private var saved = false

    var body: some View {
        VStack(spacing: 22) {
            HStack(spacing: 16) {
                ForEach(0..<3, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.primary.opacity(0.12))
                        .frame(width: 64, height: 64)
                }
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Brand.gradient)
                        .frame(width: 64, height: 64)
                    KeepsakeMark(size: 44, monochrome: true)
                }
                .scaleEffect(pop ? 1.18 : 1)
                .shadow(color: Brand.blue.opacity(pop ? 0.6 : 0), radius: 16)
            }
            .padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))

            Label(saved ? "Saved to Photos" : "Saving…", systemImage: saved ? "checkmark.circle.fill" : "arrow.down.circle")
                .font(.headline)
                .foregroundStyle(saved ? .green : .secondary)
                .contentTransition(.symbolEffect(.replace))
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
        }
        .onAppear { run() }
        .onChange(of: animate) { _, _ in run() }
    }

    private func run() {
        pop = false
        saved = false
        guard animate else { saved = true; return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.5).delay(0.3)) { pop = true }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7).delay(0.9)) { pop = false }
        withAnimation(.snappy.delay(1.4)) { saved = true }
    }
}

/// Feature pills floating in.
private struct QualityHero: View {
    var animate: Bool
    @State private var shown = false

    private let pills: [(String, String)] = [
        ("sparkles.tv", "Up to 4K"),
        ("waveform", "Video + audio merged"),
        ("wifi", "Wi-Fi only option"),
        ("capsule.fill", "Dynamic Island progress"),
    ]

    var body: some View {
        VStack(spacing: 12) {
            ForEach(pills.indices, id: \.self) { i in
                Label(pills[i].1, systemImage: pills[i].0)
                    .font(.headline)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Brand.gradient, lineWidth: 1.5))
                    .offset(x: shown ? 0 : (i.isMultiple(of: 2) ? -40 : 40))
                    .opacity(shown ? 1 : 0)
                    .animation(.spring(response: 0.55, dampingFraction: 0.75).delay(Double(i) * 0.12), value: shown)
            }
        }
        .onAppear { shown = !animate }
        .onChange(of: animate) { _, active in
            shown = false
            if active { DispatchQueue.main.async { shown = true } } else { shown = true }
        }
        .task { if animate { shown = true } }
    }
}
