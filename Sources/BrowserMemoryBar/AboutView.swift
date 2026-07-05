import MacFaceKit
import SwiftUI
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
        items.append(MenuAction(title: "Quit RememBar", systemImage: "power") {
            NSApplication.shared.terminate(nil)
        })
        if onUninstall != nil {
            items.append(MenuAction(title: "Uninstall RememBar…", systemImage: "trash",
                                    destructive: true) { confirmingRemoval = true })
        }
        return items
    }

    var body: some View {
        // The SAME identity card as TermTile — icon · name · version · made-with · ··· · GitHub/License ·
        // separator. RememBar supplies its description as the content below the separator.
        AppIdentityCard(
            name: RememBarPaths.appName,
            version: AppInfo.fromBundle().displayVersion,
            repoURL: RememBarPaths.repoURL,
            licenseURL: RememBarPaths.licenseURL,
            bundledIcon: appIcon,
            actions: overflowActions
        ) {
            Text("A minimalist menu-bar search for your system files, browser history, password "
                + "managers, and more.")
                .font(Tokens.caption)
                .foregroundStyle(Tokens.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        // Cap the identity column to TermTile's popover width (280) so the card renders at the same size,
        // then CENTER it horizontally in the wider settings window (which is ≥380 for the alias editor) so
        // it reads as balanced, not a left-hugging block with a right gap.
        .frame(maxWidth: 280)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Tokens.panel)
        .alert("Uninstall RememBar?", isPresented: $confirmingRemoval) {
            Button("Move to Trash", role: .destructive) { onUninstall?() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("RememBar and its data (preferences, caches, and the diagnostics log) will be moved "
                + "to the Trash. Full Disk Access stays in System Settings › Privacy & Security until "
                + "you remove it there.")
        }
    }
}
