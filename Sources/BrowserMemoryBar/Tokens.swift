import SwiftUI

enum Tokens {
    static let space: CGFloat = 8
    static let micro: CGFloat = 4
    static let radius: CGFloat = 8
    static let control: CGFloat = 34        // search-bar / settings-box height
    static let controlButton: CGFloat = 26  // shared height for every icon + action control

    static let panel = Color(red: 0.083, green: 0.087, blue: 0.094)
    static let field = Color(red: 0.059, green: 0.063, blue: 0.071)
    static let row = Color(red: 0.114, green: 0.118, blue: 0.126)
    static let rowActive = Color(red: 0.137, green: 0.141, blue: 0.153)
    static let line = Color(red: 0.204, green: 0.212, blue: 0.228)
    static let lineStrong = Color(red: 0.357, green: 0.369, blue: 0.392)
    static let text = Color(red: 0.949, green: 0.953, blue: 0.957)
    static let muted = Color(red: 0.596, green: 0.616, blue: 0.643)
    static let quiet = Color(red: 0.451, green: 0.475, blue: 0.506)
    static let warning = Color(red: 0.941, green: 0.635, blue: 0.271)
    // Primary-action blue (macOS dark-mode system accent) — used for the confirming button in the
    // update flow, matching Sparkle's own Install button.
    static let accent = Color(red: 0.039, green: 0.518, blue: 1.0)

    static let body = Font.system(size: 13)
    static let caption = Font.system(size: 12)
    static let label = Font.system(size: 10, weight: .semibold)
}

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
