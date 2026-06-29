import Foundation
import Sparkle

/// The single update primitive for the app. Wraps Sparkle's standard controller so the rest of
/// the app only ever sees `checkForUpdates()` — no second, homegrown updater.
///
/// `startingUpdater: false` for now: the updater is started lazily on first check, so it cannot
/// throw a no-feed error alert (or the first-launch automatic-check permission prompt) before the
/// appcast feed + signing key (Stage 2) exist.
@MainActor
final class SparkleUpdater {
    static let shared = SparkleUpdater()

    private let controller: SPUStandardUpdaterController

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// Starts the updater on first use, then checks. Safe to call before a feed is configured.
    ///
    /// Drives the controller's OWN idempotent start (not the underlying `updater.start()`): it keeps
    /// the controller's started-state coherent and lets it surface a misconfiguration rather than
    /// swallowing it. Because `startingUpdater` was `false`, the start happens here on first click —
    /// never at launch — so there's no premature automatic-update-check prompt.
    func checkForUpdates() {
        controller.startUpdater()
        controller.checkForUpdates(nil)
    }
}
