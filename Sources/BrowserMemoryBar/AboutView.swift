import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// The "?" control — not settings: an About panel answering what this is, who made it, and where
/// to learn more.
struct AboutControl: View {
    var onCheckForUpdates: (() -> Void)?
    @State private var showAbout = false

    var body: some View {
        IconControlButton(size: Tokens.control, radius: Tokens.radius, action: { showAbout.toggle() }) {
            Image(systemName: "questionmark")
                .font(.system(size: 14, weight: .semibold))
        }
        .accessibilityLabel("About RememBar")
        .popover(isPresented: $showAbout, arrowEdge: .bottom) {
            AboutPopover(onCheckForUpdates: onCheckForUpdates)
        }
    }
}

struct AboutPopover: View {
    /// Optional so the offscreen render harness stays Sparkle-free; the app injects the real check.
    var onCheckForUpdates: (() -> Void)?

    private var versionLine: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.space) {
            // Header: icon (left, larger) + name / version / Check-for-Updates stacked to its right.
            HStack(alignment: .center, spacing: Tokens.space + Tokens.micro) {
                AppIconView()
                    .frame(width: 68, height: 68)

                VStack(alignment: .leading, spacing: 3) {
                    Text("RememBar")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Tokens.text)
                    Text(versionLine)
                        .font(Tokens.caption)
                        .foregroundStyle(Tokens.muted)
                    if let onCheckForUpdates {
                        CheckForUpdatesBar(action: onCheckForUpdates)
                            .padding(.top, Tokens.micro)
                    }
                }

                Spacer(minLength: 0)
            }

            Divider().overlay(Tokens.line)

            // What it does
            Text("A minimalistic menu-bar search for your system files, browser history, 1Password, etc.")
                .font(Tokens.caption)
                .foregroundStyle(Tokens.muted)
                .fixedSize(horizontal: false, vertical: true)

            // Where to learn more
            LearnMoreLink(
                displayText: "ecn.dev/apps/RememBar",
                url: URL(string: "https://ecn.dev/apps/RememBar")!
            )

            // Quietest footer
            Text("© 2026 Evan C. Navarro")
                .font(Tokens.caption)
                .foregroundStyle(Tokens.quiet)
        }
        .padding(Tokens.space + Tokens.micro)
        .frame(width: 320, alignment: .leading)
        .background(Tokens.panel)
        // Match the system NSPopover's arrow to the panel color (see SolidPopoverChrome).
        .background(SolidPopoverChrome(color: Tokens.panel))
    }
}

/// The app's own icon (the real colorful AppIcon in the running app). Falls back to a brand tile
/// where no app icon is available (e.g. the offscreen render harness).
private struct AppIconView: View {
    var body: some View {
        if let icon = NSApplication.shared.applicationIconImage {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
        } else {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Tokens.field)
                .overlay(
                    Text("Rb")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(Tokens.muted)
                )
        }
    }
}

/// Inline "Learn more at  <globe> link <↗>" — the link portion is clickable, brightens and
/// underlines on hover, and opens in the default browser.
private struct LearnMoreLink: View {
    let displayText: String
    let url: URL
    @State private var hovered = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            openURL(url)
        } label: {
            HStack(spacing: Tokens.micro + 1) {
                Text("Learn more:")
                    .foregroundStyle(Tokens.muted)
                Image(systemName: "globe")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Tokens.text)
                Text(displayText)
                    .fontWeight(.semibold)
                    .foregroundStyle(Tokens.text)
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Tokens.text)
            }
            .font(Tokens.caption)
            .frame(maxWidth: .infinity)
            .frame(height: Tokens.controlButton + 4)
            .background(
                RoundedRectangle(cornerRadius: Tokens.radius, style: .continuous)
                    .fill(hovered ? Tokens.rowActive : Tokens.row)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.radius, style: .continuous)
                    .stroke(hovered ? Tokens.lineStrong : Tokens.line, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel("Learn more at \(url.absoluteString)")
    }
}

/// A compact bordered "bar" button (sits under the version in the About header) that triggers a
/// Sparkle update check. Brightens on hover, matching the other About controls.
private struct CheckForUpdatesBar: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Tokens.micro + 1) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 10, weight: .semibold))
                Text("Check for Updates")
                    .font(Tokens.caption.weight(.medium))
            }
            .foregroundStyle(hovered ? Tokens.text : Tokens.muted)
            .padding(.horizontal, Tokens.space)
            .frame(height: Tokens.controlButton)
            .background(
                RoundedRectangle(cornerRadius: Tokens.radius, style: .continuous)
                    .fill(hovered ? Tokens.rowActive : Tokens.row)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.radius, style: .continuous)
                    .stroke(hovered ? Tokens.lineStrong : Tokens.line, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel("Check for Updates")
    }
}

/// Walks up to the enclosing NSPopover's NSVisualEffectView and replaces its translucent material
/// with a solid color, so the popover (and its arrow) match the panel exactly.
private struct SolidPopoverChrome: NSViewRepresentable {
    let color: Color

    func makeNSView(context: Context) -> NSView {
        let probe = NSView()
        DispatchQueue.main.async { [weak probe] in
            var ancestor = probe?.superview
            while let current = ancestor, !(current is NSVisualEffectView) {
                ancestor = current.superview
            }
            guard let effect = ancestor as? NSVisualEffectView else { return }
            effect.state = .inactive
            effect.material = .windowBackground
            effect.wantsLayer = true
            effect.layer?.backgroundColor = NSColor(color).cgColor
        }
        return probe
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
