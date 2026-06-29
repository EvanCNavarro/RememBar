@testable import BrowserMemoryBar
import Testing

@Suite struct SparkleUpdaterTests {
    /// Constructing the shared updater must not crash or hang even with no running app and no feed
    /// configured — `startingUpdater: false` keeps the controller inert until `checkForUpdates()`.
    /// This exercises the Sparkle framework init path that the app's "Check for Updates…" relies on.
    @Test @MainActor func sharedUpdaterConstructsWithoutCrashing() {
        _ = SparkleUpdater.shared
    }
}
