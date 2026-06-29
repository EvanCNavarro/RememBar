import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// The "?" control — not settings: an About panel answering what this is, who made it, and where
/// to learn more.
struct AboutControl: View {
    var onCheckForUpdates: (() -> Void)?
    var onUninstall: (() -> Void)?
    @State private var showAbout = false

    var body: some View {
        IconControlButton(size: Tokens.control, radius: Tokens.radius, action: { showAbout.toggle() }) {
            Image(systemName: "questionmark")
                .font(.system(size: 14, weight: .semibold))
        }
        .accessibilityLabel("About RememBar")
        .popover(isPresented: $showAbout, arrowEdge: .bottom) {
            AboutPopover(onCheckForUpdates: onCheckForUpdates, onUninstall: onUninstall)
        }
    }
}

struct AboutPopover: View {
    /// Optional so the offscreen render harness stays Sparkle-free; the app injects the real check.
    var onCheckForUpdates: (() -> Void)?
    /// Optional for the same reason — the app injects the real "move RememBar to the Trash" action.
    var onUninstall: (() -> Void)?

    @State private var confirmingRemoval = false

    private var versionLine: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.space) {
            // Header: icon (left, larger) + name / version / "made with" stacked to its right, with
            // the "…" actions control pinned top-right.
            HStack(alignment: .top, spacing: Tokens.space + Tokens.micro) {
                AppIconView()
                    .frame(width: 68, height: 68)

                VStack(alignment: .leading, spacing: 3) {
                    Text("RememBar")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Tokens.text)
                    Text(versionLine)
                        .font(Tokens.caption)
                        .foregroundStyle(Tokens.muted)
                    MadeWithSignoff()
                        .padding(.top, 1)
                }

                Spacer(minLength: 0)

                if onCheckForUpdates != nil || onUninstall != nil {
                    AboutActionsMenu(
                        onCheckForUpdates: onCheckForUpdates,
                        onRemove: onUninstall == nil ? nil : { confirmingRemoval = true }
                    )
                }
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
        }
        .padding(Tokens.space + Tokens.micro)
        .frame(width: 320, alignment: .leading)
        .background(Tokens.panel)
        // Match the system NSPopover's arrow to the panel color (see SolidPopoverChrome).
        .background(SolidPopoverChrome(color: Tokens.panel))
        .alert("Remove RememBar?", isPresented: $confirmingRemoval) {
            Button("Move to Trash", role: .destructive) { onUninstall?() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("RememBar and its data (preferences, caches, and the diagnostics log) will be moved "
                + "to the Trash. Full Disk Access stays in System Settings › Privacy & Security until "
                + "you remove it there.")
        }
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
                    .underline(hovered, pattern: .solid) // only the URL text reacts, not the icons
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Tokens.text)
            }
            .font(Tokens.caption)
            .frame(maxWidth: .infinity)
            .frame(height: Tokens.controlButton + 4)
            .background(
                RoundedRectangle(cornerRadius: Tokens.radius, style: .continuous)
                    .fill(Tokens.row)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.radius, style: .continuous)
                    .stroke(Tokens.line, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel("Learn more at \(url.absoluteString)")
    }
}

/// The "…" actions control pinned top-right of the About panel. A click reveals a small popover with
/// "Check for Updates" and the rare/destructive "Remove RememBar…", keeping both out of the body.
private struct AboutActionsMenu: View {
    var onCheckForUpdates: (() -> Void)?
    var onRemove: (() -> Void)?
    @State private var hovered = false
    @State private var showActions = false

    var body: some View {
        Button {
            showActions.toggle()
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle((hovered || showActions) ? Tokens.text : Tokens.muted)
                .frame(width: Tokens.control, height: Tokens.control)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.radius, style: .continuous)
                        .fill((hovered || showActions) ? Tokens.rowActive : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel("More actions")
        .popover(isPresented: $showActions, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 1) {
                if let onCheckForUpdates {
                    AboutMenuRow(title: "Check for Updates", systemImage: "arrow.triangle.2.circlepath") {
                        showActions = false
                        onCheckForUpdates()
                    }
                }
                if let onRemove {
                    AboutMenuRow(title: "Remove RememBar…", systemImage: "trash", destructive: true) {
                        showActions = false
                        onRemove()
                    }
                }
            }
            .padding(Tokens.micro)
            .frame(width: 210)
            .background(Tokens.panel)
            .background(SolidPopoverChrome(color: Tokens.panel))
        }
    }
}

/// One row inside the About "…" popover.
private struct AboutMenuRow: View {
    let title: String
    let systemImage: String
    var destructive = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Tokens.micro + 1) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 16)
                Text(title)
                Spacer(minLength: 0)
            }
            .font(Tokens.caption)
            .foregroundStyle(destructive ? Color.red : Tokens.text)
            .padding(.horizontal, Tokens.micro + 2)
            .frame(height: Tokens.controlButton)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: Tokens.radius - 1, style: .continuous)
                    .fill(hovered ? Tokens.rowActive : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// The quiet "made with" sign-off under the version. The heart is an icon, never an emoji.
private struct MadeWithSignoff: View {
    var body: some View {
        HStack(spacing: Tokens.micro) {
            Text("Made with")
            Image(systemName: "heart.fill")
                .font(.system(size: 9))
                .foregroundStyle(.pink)
            Text("& Vibes")
        }
        .font(Tokens.caption)
        .foregroundStyle(Tokens.quiet)
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
