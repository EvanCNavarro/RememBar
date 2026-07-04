import AppKit
import SwiftUI

/// A floating panel that CAN take key focus — required so the editor's `TextField`s accept typing.
/// A borderless/nonactivating panel won't become key by default; these overrides opt it in.
final class FloatingEditorPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    /// Escape → close, the standard cancel affordance (no key-monitor needed).
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// Presents the Term Families editor as a lightweight, tooltip-style floating panel.
///
/// NOT a `.popover` like the About "?": a SwiftUI popover nested in a `MenuBarExtra(.window)` renders
/// in a child window that must become key for its text fields to accept typing — but the menu-bar
/// window dismisses the instant it resigns key, taking the popover with it. (The "?" popover survives
/// only because it has no text fields.) A **non-activating `NSPanel`** is the surface that's lighter
/// than a full window — no Dock icon, no `NSApp` activation-policy juggling on this `LSUIElement`
/// app — yet, with `canBecomeKey` overridden, can still host editable fields.
@MainActor
enum AliasEditorWindowController {
    private static var panel: FloatingEditorPanel?
    private static var monitors: [Any] = []

    static func show(catalog: AliasCatalog) {
        if let existing = panel {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        // .nonactivatingPanel MUST be set at init (toggling it later leaves the WindowServer's
        // activation tag stale — a panel that looks focused but silently drops keystrokes).
        let created = FloatingEditorPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .closable],
            backing: .buffered,
            defer: false
        )
        created.titleVisibility = .hidden
        created.titlebarAppearsTransparent = true
        created.isMovableByWindowBackground = true
        created.level = .floating
        created.isReleasedWhenClosed = false
        created.hidesOnDeactivate = false
        created.backgroundColor = NSColor(Tokens.panel)
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            created.standardWindowButton(button)?.isHidden = true
        }
        created.onCancel = { AliasEditorWindowController.close() }
        created.contentView = NSHostingView(
            rootView: AliasEditorView(model: AliasEditorModel(catalog: catalog))
        )
        created.setContentSize(NSSize(width: 460, height: 420))
        created.center()
        created.makeKeyAndOrderFront(nil)
        panel = created
        installDismissMonitors()
    }

    static func close() {
        panel?.orderOut(nil)
        panel = nil
        removeDismissMonitors()
    }

    /// Tooltip-style dismissal: a mouse-down anywhere outside the panel closes it (Escape is handled
    /// by the panel's `cancelOperation`). Global monitor catches other apps / the desktop; local
    /// monitor catches clicks in our own surfaces (e.g. the menu-bar icon).
    private static func installDismissMonitors() {
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            DispatchQueue.main.async { @MainActor in AliasEditorWindowController.close() }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            MainActor.assumeIsolated {
                if event.window !== panel { AliasEditorWindowController.close() }
            }
            return event
        }
        monitors = [global, local].compactMap { $0 }
    }

    private static func removeDismissMonitors() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
    }
}
