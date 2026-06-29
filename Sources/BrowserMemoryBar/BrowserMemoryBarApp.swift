import AppKit
import SwiftUI

final class RememBarAppDelegate: NSObject, NSApplicationDelegate {
    /// Set during uninstall so the terminate hook doesn't re-create the diagnostics log we just
    /// moved to the Trash.
    nonisolated(unsafe) static var isUninstalling = false

    func applicationWillTerminate(_ notification: Notification) {
        guard !Self.isUninstalling else { return }
        RememBarDiagnostics.shared.endSession(reason: "applicationWillTerminate")
    }
}

@main
struct RememBarApp: App {
    @NSApplicationDelegateAdaptor(RememBarAppDelegate.self) private var appDelegate
    @StateObject private var store = MemorySearchStore()

    init() {
        RememBarDiagnostics.shared.startSession()
    }

    /// Move RememBar's data and the app itself to the Trash, then quit. The data (the privacy-
    /// sensitive part) is always cleared; the bundle is best-effort — one in a location the user
    /// can't write stays, and they drag it to the Trash by hand. The flag stops the terminate hook
    /// from re-creating the diagnostics log we just removed.
    private func performUninstall() {
        RememBarAppDelegate.isUninstalling = true
        // Flush + end the session BEFORE the log is trashed, so no late write re-creates it.
        RememBarDiagnostics.shared.endSession(reason: "uninstall")
        let uninstaller = RememBarUninstaller()
        uninstaller.removeData()
        do {
            try uninstaller.removeBundle()
        } catch {
            // Data is cleared, but the bundle couldn't be trashed (read-only / different volume).
            // Honor the alert's promise — don't quit silently leaving a leftover that looks like a
            // failed uninstall; reveal it and tell the user to finish by hand.
            warnBundleNeedsManualRemoval()
        }
        NSApp.terminate(nil)
    }

    private func warnBundleNeedsManualRemoval() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Drag RememBar to the Trash to finish"
        alert.informativeText = "RememBar's data was removed, but the app itself couldn't be moved to "
            + "the Trash automatically (it may be on a read-only or different volume). It's now shown "
            + "in Finder — drag it to the Trash to finish removing it."
        alert.addButton(withTitle: "Reveal in Finder")
        alert.runModal()
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    var body: some Scene {
        MenuBarExtra {
            MemoryPanel(
                store: store,
                onCheckForUpdates: { SparkleUpdater.shared.checkForUpdates() },
                onUninstall: { performUninstall() }
            )
                .frame(width: 384)
                .onAppear {
                    RememBarDiagnostics.shared.record(RememBarDiagnosticEvent.uiMenuOpened)
                    MenuBarWindowPositioner.scheduleVisibilityCheck()
                }
        } label: {
            RememBarGlyph(active: store.isActive, hidesFromAccessibility: false)
                .accessibilityLabel("Open RememBar")
        }
        .menuBarExtraStyle(.window)
    }
}
