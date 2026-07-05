import AppKit
import SwiftUI

/// Opens (and retains) RememBar's settings window — a real, standard titled `NSWindow` hosting the
/// tabbed `SettingsRootView` (Term Families, About, …).
///
/// RememBar is an accessory app (`LSUIElement`). Showing a *focusable* window from such an app
/// unavoidably needs the activation dance — flip to `.regular` + `activate` so the window comes
/// forward and can become key (text fields won't focus otherwise), then restore `.accessory` on close
/// so no Dock icon lingers. A SwiftUI `Settings {}` scene would get the same tabbed chrome but needs
/// that identical flip *plus* fragile close-hook plumbing (no scene-native close callback). Self-owning
/// the window gives a clean `NSWindowDelegate.windowWillClose` hook instead, and a custom
/// (`SettingsRootView`) tab bar that matches RememBar's dark palette.
@MainActor
enum SettingsWindowController {
    private static var window: NSWindow?
    private static var delegate: WindowDelegate?

    static func show(
        catalog: AliasCatalog,
        onCheckForUpdates: (() -> Void)? = nil,
        onUninstall: (() -> Void)? = nil
    ) {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        NSApp.setActivationPolicy(.regular)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 460),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "RememBar Settings"
        win.isReleasedWhenClosed = false
        // Don't let macOS restore a stale frame: a resizable window is `isRestorable` by default, so a
        // once-dragged-tall settings window comes back tall on the next open — overriding the compact
        // size below and leaving the short About tab a huge vertical void. Always open at the set size.
        win.isRestorable = false
        win.contentView = NSHostingView(rootView: SettingsRootView(
            catalog: catalog,
            onCheckForUpdates: onCheckForUpdates,
            onUninstall: onUninstall
        ))
        win.setContentSize(NSSize(width: 400, height: 460))
        win.center()
        let del = WindowDelegate()
        win.delegate = del
        delegate = del
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
        // The 460 above is just a sane opening size; `WindowContentSizer` (in SettingsRootView) then
        // resizes the window to hug the selected tab's content on appear + every tab switch — so the
        // window always fits its content, with no vertical void, whatever height it opened at.
    }

    /// Restores the accessory (menu-bar-only) activation policy when settings close, so RememBar
    /// doesn't leave a Dock icon behind after the window is dismissed.
    private final class WindowDelegate: NSObject, NSWindowDelegate {
        func windowWillClose(_ notification: Notification) {
            SettingsWindowController.window = nil
            SettingsWindowController.delegate = nil
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
