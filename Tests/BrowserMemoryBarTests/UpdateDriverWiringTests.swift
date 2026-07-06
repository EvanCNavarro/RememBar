@testable import BrowserMemoryBar
import Foundation
@testable import MacFaceKit
import Testing

/// Pins the download-flow wiring: RememBar's `SPUUserDriver` adapter forwards each of Sparkle's download
/// callbacks to the RIGHT `UpdateWindowController` method with the right argument. The controller's own
/// morph + byte math are covered in MacFaceKit's `UpdateWindowControllerTests`; this covers the ONLY
/// RememBar-owned code in that flow — the 7 one-line forwards — which no other test exercised as a
/// sequence. A mis-wire (e.g. `showDownloadDidStartExtractingUpdate` → the wrong screen) reddens the
/// screen/heading assertions below. No Sparkle rig / server / relaunch — the driver IS the system here.
@MainActor
struct UpdateDriverWiringTests {
    @Test("download callbacks morph the controller: download→progress→preparing→ready→installing→close")
    func downloadCallbacksMorphTheController() async {
        let driver = RememBarUserDriver()
        let model = driver.controller.model

        driver.showDownloadInitiated(cancellation: {})
        guard case let .progress(heading1, _) = model.screen else { Issue.record("expected .progress"); return }
        #expect(heading1 == "Downloading update…")
        #expect(model.fraction == 0)

        driver.showDownloadDidReceiveExpectedContentLength(1000)
        driver.showDownloadDidReceiveData(ofLength: 250)
        #expect(model.fraction == 0.25)            // forwarded to the controller's byte math

        driver.showDownloadDidStartExtractingUpdate()
        guard case let .progress(heading2, _) = model.screen else { Issue.record("expected .progress"); return }
        #expect(heading2 == "Preparing update…")

        driver.showExtractionReceivedProgress(0.5)
        #expect(model.fraction == 0.5)

        driver.showReady(toInstallAndRelaunch: { _ in })
        guard case .ready = model.screen else { Issue.record("expected .ready"); return }

        driver.showInstallingUpdate(withApplicationTerminated: false, retryTerminatingApplication: {})
        guard case let .progress(heading3, _) = model.screen else { Issue.record("expected .progress"); return }
        #expect(heading3 == "Installing…")
        #expect(model.fraction == nil)             // installing is indeterminate

        await driver.showUpdateInstalledAndRelaunched(true)   // → controller.close() (no crash; torn down)
    }
}
