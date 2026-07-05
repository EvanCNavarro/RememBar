import SwiftUI
import MacFaceKit

/// The 400faces design tokens now live in MacFaceKit; re-export them module-wide so every
/// RememBar file keeps referring to `Tokens.x` unchanged (values identical — migration B1).
typealias Tokens = MacFaceKit.Tokens


struct IconButtonStyle: ButtonStyle {
    var active = false
    /// Hover is tracked by the owning view (ButtonStyle can't hold @State) and passed in, so every
    /// icon control brightens on hover the same way — resting look is unchanged.
    var hovered = false
    var radius = Tokens.radius

    func makeBody(configuration: Configuration) -> some View {
        let lifted = active || hovered || configuration.isPressed
        return configuration.label
            .foregroundStyle(lifted ? Tokens.text : Tokens.muted)
            .background(lifted ? Tokens.rowActive : Tokens.row)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke((active || hovered) ? Tokens.lineStrong : Tokens.line, lineWidth: 1)
            }
    }
}

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

/// A text action control — Grant access, Retry. Same height as the icon controls.
struct ActionPillButton: View {
    let title: String
    var tint: Color = Tokens.warning
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Tokens.caption.weight(.semibold))
                .foregroundStyle(Tokens.text)
                .padding(.horizontal, Tokens.space)
                .frame(height: Tokens.controlButton)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.micro, style: .continuous)
                        .fill(tint.opacity(0.28))
                )
        }
        .buttonStyle(.plain)
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
