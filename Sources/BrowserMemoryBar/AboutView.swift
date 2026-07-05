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

    /// Version without the "Version " prefix (AppHeader adds it).
    private var versionText: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    private var appIcon: NSImage? {
        Bundle.packagedResourceURL("RememBarAppIcon", withExtension: "png").flatMap(NSImage.init(contentsOf:))
    }

    /// The `···` meta-actions — the SAME OverflowMenu TermTile uses, RememBar just supplies its own items.
    private var overflowActions: [MenuAction] {
        var items: [MenuAction] = []
        if let onCheckForUpdates {
            items.append(MenuAction(title: "Check for Updates",
                                    systemImage: "arrow.triangle.2.circlepath", action: onCheckForUpdates))
        }
        if onUninstall != nil {
            items.append(MenuAction(title: "Remove RememBar…", systemImage: "trash",
                                    destructive: true) { confirmingRemoval = true })
        }
        return items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.gap) {
            // The SHARED identity header — icon + name + version + made-with + the ··· overflow. Only the
            // dynamic pieces (name/version/icon/actions) differ from TermTile.
            AppHeader(name: "RememBar", version: versionText, bundledIcon: appIcon) {
                OverflowMenu(overflowActions)
            }

            Text("A minimalist menu-bar search for your system files, browser history, password "
                + "managers, and more.")
                .font(Tokens.caption)
                .foregroundStyle(Tokens.muted)
                .fixedSize(horizontal: false, vertical: true)

            LearnMoreLink(
                displayText: "ecn.dev/apps/RememBar",
                url: URL(string: "https://ecn.dev/apps/RememBar")!
            )

            Spacer(minLength: 0)
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



