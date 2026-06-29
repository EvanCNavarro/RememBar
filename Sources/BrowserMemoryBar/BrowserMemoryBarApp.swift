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
        let uninstaller = RememBarUninstaller()
        uninstaller.removeData()
        try? uninstaller.removeBundle()
        NSApp.terminate(nil)
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
