import SwiftUI
import MacFaceKit
#if canImport(AppKit)
import AppKit
#endif

/// The About tab of the settings window: what RememBar is, who made it, its version, where to learn
/// more, and the app-level actions (check for updates, uninstall) as first-class rows.
struct AboutTab: View {
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
        VStack(spacing: Tokens.space) {
            Spacer(minLength: Tokens.space)

            AppIconView()
                .frame(width: 84, height: 84)

            VStack(spacing: 3) {
                Text("RememBar")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Tokens.text)
                Text(versionLine)
                    .font(Tokens.caption)
                    .foregroundStyle(Tokens.muted)
            }

            Text("A minimalist menu-bar search for your system files, browser history, password "
                + "managers, and more.")
                .font(Tokens.caption)
                .foregroundStyle(Tokens.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Tokens.space)

            MadeWithSignoff()

            Spacer(minLength: Tokens.space)

            VStack(spacing: Tokens.micro) {
                if let onCheckForUpdates {
                    ActionRow(title: "Check for Updates", systemImage: "arrow.triangle.2.circlepath",
                                   action: onCheckForUpdates)
                }
                LearnMoreLink(
                    displayText: "ecn.dev/apps/RememBar",
                    url: URL(string: "https://ecn.dev/apps/RememBar")!
                )
                if onUninstall != nil {
                    ActionRow(title: "Remove RememBar…", systemImage: "trash", destructive: true,
                                   action: { confirmingRemoval = true })
                }
            }
        }
        .padding(Tokens.space + Tokens.micro)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.panel)
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
            let side = size.width
            func pt(_ px: CGFloat, _ py: CGFloat) -> CGPoint { CGPoint(x: px * side, y: py * side) }
            let line = side * 0.09

            // Antenna: a stem with a ball on top.
            var stem = Path()
            stem.move(to: pt(0.5, 0.14))
            stem.addLine(to: pt(0.5, 0.30))
            context.stroke(stem, with: .color(color), lineWidth: line)
            let ball = side * 0.085
            context.fill(
                Path(ellipseIn: CGRect(x: 0.5 * side - ball, y: 0.06 * side, width: ball * 2, height: ball * 2)),
                with: .color(color))

            // Head.
            let head = Path(
                roundedRect: CGRect(x: 0.16 * side, y: 0.30 * side, width: 0.68 * side, height: 0.60 * side),
                cornerRadius: 0.18 * side)
            context.stroke(head, with: .color(color), lineWidth: line)

            // Eyes.
            let eye = side * 0.08
            for cx in [0.37, 0.63] {
                context.fill(
                    Path(ellipseIn: CGRect(x: cx * side - eye, y: 0.58 * side - eye, width: eye * 2, height: eye * 2)),
                    with: .color(color))
            }
        }
    }
}
