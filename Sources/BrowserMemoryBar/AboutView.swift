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
    @State private var showActions = false

    init(onCheckForUpdates: (() -> Void)? = nil, onUninstall: (() -> Void)? = nil, showingActions: Bool = false) {
        self.onCheckForUpdates = onCheckForUpdates
        self.onUninstall = onUninstall
        _showActions = State(initialValue: showingActions)
    }

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
                    EllipsisButton(isOn: $showActions)
                }
            }

            Divider().overlay(Tokens.line)

            // What it does
            Text("A minimalistic menu-bar search for your system files, browser history, password managers, etc.")
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
        .overlay {
            if showActions {
                // Tap catcher (dismiss on outside click) BEHIND the dropdown as ZStack siblings, so
                // hover reaches the dropdown rows (an .overlay-of-the-catcher can swallow it).
                ZStack(alignment: .topTrailing) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { showActions = false }
                    ActionsDropdown(
                        onCheckForUpdates: onCheckForUpdates,
                        onRemove: onUninstall == nil ? nil : { confirmingRemoval = true },
                        dismiss: { showActions = false }
                    )
                    .padding(.top, 46)
                    .padding(.trailing, Tokens.space + Tokens.micro)
                }
            }
        }
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

/// The app's own icon. Prefers the real AppIcon from the module bundle so it renders correctly in
/// the dev gallery AND the shipped app — `NSApp.applicationIconImage` is only the real icon once the
/// app is bundled (a generic folder in `swift run`). Falls back to the runtime icon, then a brand tile.
struct AppIconView: View {
    private static let bundledIcon: NSImage? = {
        guard let url = Bundle.packagedResourceURL("RememBarAppIcon", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()

    var body: some View {
        if let icon = Self.bundledIcon ?? NSApplication.shared.applicationIconImage {
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

    var body: some View {
        Button {
            // NSWorkspace, not SwiftUI openURL — the latter silently no-ops in an inactive
            // menu-bar (.accessory) app.
            NSWorkspace.shared.open(url)
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

/// The "…" button pinned top-right of the About panel; toggles the actions dropdown. Uses the same
/// `IconControlButton` as the search panel's "?" so the two read as a matched pair — same size,
/// radius, outline, and hover response (active while the dropdown is open).
private struct EllipsisButton: View {
    @Binding var isOn: Bool

    var body: some View {
        IconControlButton(size: Tokens.control, radius: Tokens.radius, active: isOn, action: { isOn.toggle() }) {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
        }
        .accessibilityLabel("More actions")
    }
}

/// A self-contained dropdown card (right-aligned under the "…") with the panel's actions. Rendered
/// as an in-panel overlay — not a system menu/popover — so it stays INSIDE the About panel, keeps
/// its icons, and gives the destructive row a proper red hover.
private struct ActionsDropdown: View {
    var onCheckForUpdates: (() -> Void)?
    var onRemove: (() -> Void)?
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let onCheckForUpdates {
                AboutMenuRow(title: "Check for Updates", systemImage: "arrow.triangle.2.circlepath") {
                    dismiss()
                    onCheckForUpdates()
                }
            }
            if let onRemove {
                AboutMenuRow(title: "Remove RememBar…", systemImage: "trash", destructive: true) {
                    dismiss()
                    onRemove()
                }
            }
        }
        .padding(Tokens.micro)
        .frame(width: 196)
        .background(
            RoundedRectangle(cornerRadius: Tokens.radius, style: .continuous)
                .fill(Tokens.field)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.radius, style: .continuous)
                .stroke(Tokens.line, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
    }
}

/// One row in the actions dropdown — icon + title with a hover highlight. The destructive row is red
/// text, then red fill / white text on hover (the macOS delete-item feel).
private struct AboutMenuRow: View {
    let title: String
    let systemImage: String
    var destructive = false
    let action: () -> Void
    @State private var hovered = false

    private var foreground: Color {
        if destructive { return hovered ? .white : .red }
        return Tokens.text
    }

    private var rowFill: Color {
        guard hovered else { return .clear }
        return destructive ? .red : Tokens.rowActive
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Tokens.micro + 2) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 15)
                Text(title)
                Spacer(minLength: 0)
            }
            .font(Tokens.caption)
            .foregroundStyle(foreground)
            .padding(.horizontal, Tokens.micro + 2)
            .frame(height: Tokens.controlButton)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: Tokens.radius - 1, style: .continuous)
                    .fill(rowFill)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// The quiet "made with ♥ & robots" sign-off under the version. Both glyphs are icons (no emoji);
/// the robot is hand-drawn because macOS 14 has no robot SF Symbol — a generic robot says "built
/// with AI" without leaning on any vendor's logo.
private struct MadeWithSignoff: View {
    var body: some View {
        HStack(spacing: Tokens.micro) {
            Text("Made with")
            Image(systemName: "heart.fill")
                .font(.system(size: 9))
                .foregroundStyle(.pink)
            Text("&")
            RobotGlyph(color: Tokens.muted)
                .frame(width: 13, height: 13)
        }
        .font(Tokens.caption)
        .foregroundStyle(Tokens.quiet)
    }
}

/// A minimal robot head (antenna + rounded head + two eyes), drawn so it reads cleanly at ~13pt.
private struct RobotGlyph: View {
    var color: Color

    var body: some View {
        Canvas { context, size in
            let s = size.width
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
            let line = s * 0.09

            // Antenna: a stem with a ball on top.
            var stem = Path()
            stem.move(to: pt(0.5, 0.14))
            stem.addLine(to: pt(0.5, 0.30))
            context.stroke(stem, with: .color(color), lineWidth: line)
            let ball = s * 0.085
            context.fill(Path(ellipseIn: CGRect(x: 0.5 * s - ball, y: 0.06 * s, width: ball * 2, height: ball * 2)),
                         with: .color(color))

            // Head.
            let head = Path(roundedRect: CGRect(x: 0.16 * s, y: 0.30 * s, width: 0.68 * s, height: 0.60 * s),
                            cornerRadius: 0.18 * s)
            context.stroke(head, with: .color(color), lineWidth: line)

            // Eyes.
            let eye = s * 0.08
            for cx in [0.37, 0.63] {
                context.fill(Path(ellipseIn: CGRect(x: cx * s - eye, y: 0.58 * s - eye, width: eye * 2, height: eye * 2)),
                             with: .color(color))
            }
        }
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
