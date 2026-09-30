import SwiftUI

/// Keepsake's visual identity, shared by the app, the share sheet and the Live Activity.
enum Brand {
    static let name = "Keepsake"

    static let teal = Color(red: 0.05, green: 0.65, blue: 0.64)
    static let blue = Color(red: 0.23, green: 0.51, blue: 0.96)
    static let indigo = Color(red: 0.39, green: 0.40, blue: 0.95)

    static let gradient = LinearGradient(
        colors: [teal, blue, indigo],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let softGradient = LinearGradient(
        colors: [teal.opacity(0.18), blue.opacity(0.14), indigo.opacity(0.18)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

/// The Keepsake mark: a small stack of photo cards with a download arrow on the front card.
/// Drawn in SwiftUI so it stays sharp at any size.
struct KeepsakeMark: View {
    var size: CGFloat = 44
    /// Tilts the back cards a little further when true (used for playful animations).
    var fanned: Bool = false
    /// Draws the arrow in white on a transparent card (for use on top of the gradient).
    var monochrome: Bool = false

    var body: some View {
        let card = size * 0.62
        let radius = card * 0.2
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(monochrome ? Color.white.opacity(0.35) : Brand.teal.opacity(0.45))
                .frame(width: card, height: card * 1.12)
                .rotationEffect(.degrees(fanned ? -20 : -13))
                .offset(x: -size * (fanned ? 0.13 : 0.1), y: size * 0.02)
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(monochrome ? Color.white.opacity(0.6) : Brand.blue.opacity(0.65))
                .frame(width: card, height: card * 1.12)
                .rotationEffect(.degrees(fanned ? 17 : 10))
                .offset(x: size * (fanned ? 0.13 : 0.1), y: size * 0.01)
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(monochrome ? AnyShapeStyle(Color.white) : AnyShapeStyle(Brand.gradient))
                .frame(width: card, height: card * 1.12)
                .shadow(color: .black.opacity(0.18), radius: size * 0.05, y: size * 0.03)
                .overlay {
                    Image(systemName: "arrow.down")
                        .font(.system(size: card * 0.46, weight: .heavy, design: .rounded))
                        .foregroundStyle(monochrome ? AnyShapeStyle(Brand.blue) : AnyShapeStyle(Color.white))
                }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
