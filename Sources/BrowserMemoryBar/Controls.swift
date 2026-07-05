import MacFaceKit
import SwiftUI

/// The 400faces design tokens now live in MacFaceKit; re-export them module-wide so every
/// RememBar file keeps referring to `Tokens.x` unchanged (values identical — migration B1).
typealias Tokens = MacFaceKit.Tokens

/// A square icon control — clear, submit, paginate, settings, the About "?" and "…". One height,
/// radius, and hover response everywhere.
struct IconControlButton<Content: View>: View {
    var size: CGFloat = Tokens.controlButton
    var radius: CGFloat = Tokens.micro
    var active = false
    let action: () -> Void
    @ViewBuilder var content: Content
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            content.frame(width: size, height: size)
        }
        .buttonStyle(IconButtonStyle(active: active, hovered: hovered, radius: radius))
        .onHover { hovered = $0 }
    }
}

struct ResultButtonStyle: ButtonStyle {
    let isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(isActive || configuration.isPressed ? Tokens.rowActive : Tokens.row)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.radius, style: .continuous)
                    .stroke(isActive ? Tokens.lineStrong : Tokens.line, lineWidth: 1)
            }
    }
}
