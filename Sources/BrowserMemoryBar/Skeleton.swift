import SwiftUI

/// True in the offscreen ImageRenderer harness — loading/entrance animations start completed there
/// so the static snapshot isn't captured mid-state (blank rows / stuck skeletons).
let isOffscreenRender = ProcessInfo.processInfo.environment["REMEMBAR_RENDER_DIR"] != nil

/// A soft left-to-right highlight sweep for loading placeholders, masked to the content's shape.
struct Shimmer: ViewModifier {
    @State private var travel: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { geo in
                    let width = max(geo.size.width, 1)
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: Color.white.opacity(0.07), location: 0.5),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: width * 0.7)
                    .offset(x: travel * width * 1.7)
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
                }
                .mask(content)
            }
            .onAppear {
                withAnimation(.linear(duration: 1.25).repeatForever(autoreverses: false)) {
                    travel = 1
                }
            }
    }
}

extension View {
    /// Overlay a repeating shimmer sweep (for skeleton placeholders).
    func shimmer() -> some View { modifier(Shimmer()) }
}

/// A shimmering skeleton block — the base for thumbnail and row loading placeholders.
struct SkeletonBlock: View {
    var cornerRadius: CGFloat = Tokens.micro

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Tokens.field)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Tokens.line.opacity(0.6), lineWidth: 1)
            )
            .shimmer()
    }
}
