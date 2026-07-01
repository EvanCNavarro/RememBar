import Foundation
import Sparkle

/// The single update primitive for the app. By default it drives Sparkle through `RememBarUserDriver`
/// — our custom user driver — so the update UI matches the app's design. Sparkle still performs every
/// security-critical step (download, EdDSA verification, atomic install, relaunch); the driver only
/// presents the flow.
///
/// Rollback is built in: set `REMEMBAR_STOCK_UPDATER=1` to use Sparkle's stock `SPUStandardUpdaterController`
/// UI instead, and if the custom updater fails to start it falls back to the stock controller
/// automatically rather than leaving the user unable to update.
///
/// The updater is started lazily on the first check (never at launch), so it cannot surface a no-feed
/// error or the first-launch automatic-check prompt before the user asks to check.
@MainActor
final class SparkleUpdater {
    static let shared = SparkleUpdater()

    private let preferStockUpdater = ProcessInfo.processInfo.environment["REMEMBAR_STOCK_UPDATER"] != nil

    private var customUpdater: SPUUpdater?
    private var customDriver: RememBarUserDriver?
    private var stockController: SPUStandardUpdaterController?

    private init() {}

    /// Starts the updater on first use, then checks. Safe to call before a feed is configured.
    func checkForUpdates() {
        if preferStockUpdater {
            checkWithStockController()
        } else {
            checkWithCustomDriver()
        }
    }

    private func checkWithCustomDriver() {
        if customUpdater == nil {
            let driver = RememBarUserDriver()
            let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: nil)
            do {
                try updater.start()
                customDriver = driver
                customUpdater = updater
            } catch {
                // Misconfiguration — fall back to the stock controller so the user can still update.
                checkWithStockController()
                return
            }
        }
        customUpdater?.checkForUpdates()
    }

    private func checkWithStockController() {
        if stockController == nil {
            stockController = SPUStandardUpdaterController(
                startingUpdater: false,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
        }
        stockController?.startUpdater()
        stockController?.checkForUpdates(nil)
    }
}
