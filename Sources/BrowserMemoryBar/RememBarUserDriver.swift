import AppKit
import Sparkle
import SwiftUI

/// The model backing the update window. The driver mutates `screen` (variant transitions) and
/// `fraction` (progress ticks) separately, so a flood of download-progress callbacks updates the bar
/// in place — no re-hosting the SwiftUI on every chunk.
@MainActor
final class UpdateFlowModel: ObservableObject {
    enum Screen {
        case permission(allow: () -> Void, decline: () -> Void)
        case checking(cancel: () -> Void)
        case available(version: String, current: String, remindLater: () -> Void, install: () -> Void)
        case progress(heading: String, cancel: (() -> Void)?)
        case ready(version: String, install: () -> Void)
        case upToDate(version: String, ok: () -> Void)
        case error(message: String, ok: () -> Void)
    }

    @Published var screen: Screen = .checking(cancel: {})
    @Published var fraction: Double?
    @Published var releaseNotes: [String]?
    @Published var notesExpanded = true
    /// The version being installed (from the appcast), shown on the progress + ready screens.
    var latestVersion = "the update"
}

private struct UpdateFlowRootView: View {
    @ObservedObject var model: UpdateFlowModel

    var body: some View {
        dialog.fixedSize()
    }

    private var dialog: UpdateDialog {
        switch model.screen {
        case let .permission(allow, decline):
            return .permission(onAllow: allow, onDecline: decline)
        case let .checking(cancel):
            return .checking(onCancel: cancel)
        case let .available(version, current, remindLater, install):
            return .available(version: version, currentVersion: current,
                              notes: model.releaseNotes ?? [], notesExpanded: $model.notesExpanded,
                              onInstall: install, onRemindLater: remindLater)
        case let .progress(heading, cancel):
            return .progress(heading: heading, version: model.latestVersion,
                             fraction: model.fraction, onCancel: cancel)
        case let .ready(version, install):
            return .ready(version: version, onRestart: install)
        case let .upToDate(version, ok):
            return .upToDate(version: version, onOK: ok)
        case let .error(message, ok):
            return .error(message: message, onOK: ok)
        }
    }
}

/// RememBar's custom Sparkle user driver: presents the app's own update dialogs (UpdateFlowViews) in
/// a borderless floating window instead of Sparkle's stock UI. Sparkle still performs every
/// security-critical step (download, EdDSA verification, atomic install, relaunch); this only draws
/// the flow and relays the user's choice. All 16 required SPUUserDriver methods are implemented; the
/// three `acknowledgement` methods bridge to Swift as `async` and use continuations.
@MainActor
final class RememBarUserDriver: NSObject, SPUUserDriver, NSWindowDelegate {
    private let model = UpdateFlowModel()
    private var window: NSWindow?
    private var expectedLength: UInt64 = 0
    private var receivedLength: UInt64 = 0
    /// What to do if the user closes the window via the traffic-light control (send the appropriate
    /// cancel/dismiss/acknowledge). Cleared once fired so it can't run twice.
    private var escape: (() -> Void)?
    /// The pending acknowledgement continuation for the async (not-found / error) states.
    private var pendingAck: CheckedContinuation<Void, Never>?

    private var currentAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "this version"
    }

    // MARK: Window

    private func present() {
        let firstShow = (window == nil)
        if firstShow {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 220),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            win.titlebarAppearsTransparent = true          // dark titlebar blends with the content
            win.appearance = NSAppearance(named: .darkAqua) // real, hover-capable traffic lights
            win.backgroundColor = NSColor(updateWindowBG)
            win.isMovableByWindowBackground = true
            win.isReleasedWhenClosed = false
            win.delegate = self
            win.contentView = NSHostingView(rootView: UpdateFlowRootView(model: model))
            window = win
        }
        window?.title = ""   // no "Software Update" chrome — the header line carries the state
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if firstShow { window?.center() }
        syncWindowSize(animated: !firstShow)
    }

    /// Fit the window to the current SwiftUI content, preserving the window's center so it grows and
    /// shrinks in place (a smooth morph between states rather than a jump). Deferred a runloop tick so
    /// SwiftUI has laid out first.
    private func syncWindowSize(animated: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, let content = window.contentView else { return }
            let size = content.fittingSize
            guard size.width > 0, size.height > 0 else { return }
            let old = window.frame
            var newFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
            newFrame.origin = NSPoint(x: old.midX - newFrame.width / 2, y: old.midY - newFrame.height / 2)
            window.setFrame(newFrame, display: true, animate: animated)
        }
    }

    private func setScreen(_ screen: UpdateFlowModel.Screen, escape: (() -> Void)? = nil) {
        self.escape = escape
        withAnimation(.easeInOut(duration: 0.22)) { model.screen = screen }
        present()
    }

    /// Programmatic close (a button / Sparkle dismiss). Detaches the delegate first so the user-close
    /// path (`windowWillClose`) doesn't also fire the escape action.
    private func close() {
        // Resume any pending acknowledgement continuation so its async task can't leak if Sparkle
        // tears the dialog down before the user acknowledges (nil-guarded — a no-op in the normal
        // button path where the ack already resumed).
        resumeAck()
        escape = nil
        window?.delegate = nil
        window?.close()
        window = nil
    }

    private func resumeAck() {
        if let continuation = pendingAck {
            pendingAck = nil
            continuation.resume()
        }
    }

    /// User clicked the window's close control. Fire the escape action (cancel / dismiss / ack) once.
    func windowWillClose(_ notification: Notification) {
        let action = escape
        escape = nil
        window = nil
        action?()
    }

    // MARK: SPUUserDriver — required

    func show(_ request: SPUUpdatePermissionRequest,
              reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        let allow = {
            self.escape = nil
            reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
        }
        let decline = {
            self.escape = nil
            reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
        }
        setScreen(.permission(allow: allow, decline: decline), escape: decline)
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        model.fraction = nil
        model.releaseNotes = nil
        let cancel = { self.escape = nil; cancellation() }
        setScreen(.checking(cancel: cancel), escape: cancel)
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        model.latestVersion = appcastItem.displayVersionString
        setScreen(.available(
            version: appcastItem.displayVersionString,
            current: currentAppVersion,
            // "Remind Me Later" defers (Sparkle re-prompts on the next check) — NOT .skip, which would
            // permanently skip this version and never remind, contradicting the label.
            remindLater: { self.escape = nil; reply(.dismiss) },
            install: { self.escape = nil; reply(.install) }
        ), escape: { reply(.dismiss) })
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        guard let items = Self.noteItems(from: downloadData.data) else { return }
        withAnimation(.easeInOut(duration: 0.22)) { model.releaseNotes = items }
        syncWindowSize(animated: true)
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        // No inline notes to show; the dialog simply omits the "What's new" section.
    }

    func showUpdateNotFoundWithError(_ error: Error) async {
        await withCheckedContinuation { continuation in
            pendingAck = continuation
            let ack = { self.resumeAck(); self.close() }
            setScreen(.upToDate(version: currentAppVersion, ok: ack), escape: { self.resumeAck() })
        }
    }

    func showUpdaterError(_ error: Error) async {
        await withCheckedContinuation { continuation in
            pendingAck = continuation
            let ack = { self.resumeAck(); self.close() }
            setScreen(.error(message: error.localizedDescription, ok: ack), escape: { self.resumeAck() })
        }
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        expectedLength = 0
        receivedLength = 0
        model.fraction = 0
        let cancel = { self.escape = nil; cancellation() }
        setScreen(.progress(heading: "Downloading update…", cancel: cancel), escape: cancel)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedLength = expectedContentLength
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedLength += length
        model.fraction = expectedLength > 0 ? min(1, Double(receivedLength) / Double(expectedLength)) : nil
    }

    func showDownloadDidStartExtractingUpdate() {
        model.fraction = 0
        setScreen(.progress(heading: "Preparing update…", cancel: nil))
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        model.fraction = progress
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        setScreen(.ready(version: model.latestVersion, install: { self.escape = nil; reply(.install) }),
                  escape: { reply(.dismiss) })
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        model.fraction = nil
        setScreen(.progress(heading: "Installing…", cancel: nil))
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool) async {
        close()
    }

    func dismissUpdateInstallation() {
        close()
    }

    // MARK: SPUUserDriver — optional

    func showUpdateInFocus() {
        present()
    }

    // MARK: Release notes

    /// Parse the appcast's release-notes HTML into individual line items (bullets/paragraphs), so the
    /// dialog can render them as a structured list rather than a wall of text.
    private static func noteItems(from data: Data) -> [String]? {
        guard !data.isEmpty else { return nil }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        guard let attributed = try? NSAttributedString(data: data, options: options, documentAttributes: nil) else {
            return nil
        }
        let leadingBullets = CharacterSet(charactersIn: "•*-–—\u{2022} \t")
        let items = attributed.string
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: leadingBullets) }
            .filter { !$0.isEmpty }
        return items.isEmpty ? nil : items
    }
}
