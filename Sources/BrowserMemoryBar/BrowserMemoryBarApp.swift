import SwiftUI
import AppKit

final class RememBarAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
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

    var body: some Scene {
        MenuBarExtra {
            MemoryPanel(store: store, onCheckForUpdates: { SparkleUpdater.shared.checkForUpdates() })
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
