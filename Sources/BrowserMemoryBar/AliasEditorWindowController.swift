import AppKit
import SwiftUI

/// Opens (and retains) the Term Families editor in a real, standard titled window.
///
/// RememBar is an accessory app (`LSUIElement`). Showing a *focusable* window from such an app
/// unavoidably needs the activation dance — flip to `.regular` + `activate` so the window comes
/// forward and can become key (text fields won't focus otherwise), then restore `.accessory` on close
/// so no Dock icon lingers. A SwiftUI `Settings {}` scene gets the same tabbed-prefs chrome for free
/// but needs that identical flip *plus* fragile close-hook plumbing (no scene-native close callback —
/// you observe `NSWindow.willCloseNotification` matched by title). Self-owning the `NSWindow` gives a
/// clean `NSWindowDelegate.windowWillClose` hook instead, so it's the pragmatic choice while there's a
/// single settings surface. (Add a `Settings` scene with tabs if/when a second settings category
/// arrives — About, General, etc.)
@MainActor
enum AliasEditorWindowController {
    private static var window: NSWindow?
    private static var delegate: WindowDelegate?

    static func show(catalog: AliasCatalog) {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        NSApp.setActivationPolicy(.regular)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Term Families"
        win.isReleasedWhenClosed = false
        win.contentView = NSHostingView(rootView: AliasEditorView(model: AliasEditorModel(catalog: catalog)))
        win.setContentSize(NSSize(width: 460, height: 420))
        win.center()
        let del = WindowDelegate()
        win.delegate = del
        delegate = del
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
    }

    /// Restores the accessory (menu-bar-only) activation policy when the editor closes, so RememBar
    /// doesn't leave a Dock icon behind after the window is dismissed.
    private final class WindowDelegate: NSObject, NSWindowDelegate {
        func windowWillClose(_ notification: Notification) {
            AliasEditorWindowController.window = nil
            AliasEditorWindowController.delegate = nil
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
