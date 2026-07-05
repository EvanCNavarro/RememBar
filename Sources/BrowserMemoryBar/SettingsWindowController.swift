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
        let contentSize = NSSize(width: 400, height: 380)
        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable],   // NOT .resizable — fixed, compact
            backing: .buffered,
            defer: false
        )
        win.title = "RememBar Settings"
        win.isReleasedWhenClosed = false
        win.isRestorable = false   // don't restore a stale frame on open

        let host = NSHostingView(rootView: SettingsRootView(
            catalog: catalog,
            onCheckForUpdates: onCheckForUpdates,
            onUninstall: onUninstall
        ))
        // THE fix for the vertical-void bug: an NSHostingView by default resizes the WINDOW to the
        // SwiftUI content's ideal size. The About tab's ideal height (its wrapping description measured at
        // the content's minimum width) is ~1500pt, so the window ballooned to that with a huge void; Term
        // Families only looked fine because its ScrollView bounded the ideal. `sizingOptions = []` turns
        // that auto-resize OFF — the window stays the fixed `contentSize`, and the content fills it.
        host.sizingOptions = []
        win.contentView = host
        win.setContentSize(contentSize)
        win.center()
        let del = WindowDelegate()
        win.delegate = del
        delegate = del
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
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
