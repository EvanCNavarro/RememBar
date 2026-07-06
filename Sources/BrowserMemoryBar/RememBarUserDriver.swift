import AppKit
import MacFaceKit
import Sparkle

/// RememBar's app icon for the update dialog (its own bundled resource, so it renders under `swift run`
/// too). Shared by the driver + the dev gallery.
var rememBarUpdateIcon: NSImage? {
    Bundle.packagedResourceURL("RememBarAppIcon", withExtension: "png").flatMap(NSImage.init(contentsOf:))
}

/// RememBar's custom Sparkle user driver — a THIN adapter that translates Sparkle's `SPUUserDriver`
/// callbacks into the shared `MacFaceKit.UpdateWindowController`'s semantic `show*` API. All the window
/// hosting, morph, escape/acknowledgement bookkeeping and progress math live once in the controller; this
/// file is pure Sparkle→controller translation (the irreducible Sparkle-coupled shell, kept app-local
/// because Sparkle is a vendored binaryTarget that can't live in the public kit). Sparkle still performs
/// every security-critical step (download, EdDSA verification, atomic install, relaunch).
@MainActor
final class RememBarUserDriver: NSObject, SPUUserDriver {
    // internal (not private): the adapter-wiring test drives the SPUUserDriver callbacks and asserts
    // this controller's state morphs correctly — the only RememBar-owned code in the download flow.
    let controller = UpdateWindowController(appName: RememBarPaths.appName, icon: rememBarUpdateIcon)

    /// The running app's version, shown on the "you have X" / up-to-date lines. RememBar's own fallback
    /// ("this version") — deliberately distinct from `MacFaceKit.AppInfo`'s "dev".
    private var currentAppVersion: String {
        Bundle.main.marketingVersion ?? "this version"
    }

    // MARK: SPUUserDriver — required

    func show(_ request: SPUUpdatePermissionRequest,
              reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        controller.showPermission(
            onAllow: { reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false)) },
            onDecline: { reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false)) })
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        controller.showChecking(onCancel: cancellation)
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        controller.showAvailable(
            version: appcastItem.displayVersionString,
            currentVersion: currentAppVersion,
            // Embedded notes only (a downloaded releaseNotesLink arrives later via showUpdateReleaseNotes);
            // the gate + parse live once in the kit.
            notes: ReleaseNotesParser.embeddedItems(
                releaseNotesURL: appcastItem.releaseNotesURL,
                description: appcastItem.itemDescription,
                format: ReleaseNotesFormat(sparkleFormat: appcastItem.itemDescriptionFormat)),
            onInstall: { reply(.install) },
            // "Remind Me Later" defers (Sparkle re-prompts on the next check) — NOT .skip, which would
            // permanently skip this version and never remind, contradicting the label.
            onRemindLater: { reply(.dismiss) })
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        // The downloaded-link path — Sparkle delivers these as HTML data.
        guard let items = ReleaseNotesParser.items(from: downloadData.data) else { return }
        controller.updateReleaseNotes(items)
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        // No inline notes to show; the dialog simply omits the "What's new" section.
    }

    func showUpdateNotFoundWithError(_ error: Error) async {
        await controller.showUpToDate(version: currentAppVersion)
    }

    func showUpdaterError(_ error: Error) async {
        await controller.showError(message: error.localizedDescription)
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        controller.showDownloadStarting(onCancel: cancellation)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        controller.setExpectedContentLength(expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        controller.addReceivedBytes(length)
    }

    func showDownloadDidStartExtractingUpdate() {
        controller.showPreparing()
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        controller.updateProgress(progress)
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        controller.showReady(onRestart: { reply(.install) }, onDismiss: { reply(.dismiss) })
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        controller.showInstalling()
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool) async {
        controller.close()
    }

    func dismissUpdateInstallation() {
        controller.close()
    }

    // MARK: SPUUserDriver — optional

    func showUpdateInFocus() {
        controller.showInFocus()
    }
}
