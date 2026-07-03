import AppKit
import SwiftUI

/// Opens (and retains) the Term Families editor in a real titled window.
///
/// RememBar is an accessory app (`LSUIElement`) with no Dock icon and no app menu, so a SwiftUI
/// `Settings` scene / ⌘, is unreliable and a `SettingsLink`-opened window would come up behind other
/// apps. So we open an `NSWindow` ourselves and do the activation dance the rest of the app already
/// uses for accessory windows (see `AboutView`/gallery): flip to `.regular` + `activate` so the window
/// comes forward and takes focus, then restore `.accessory` on close so no Dock icon lingers.
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
