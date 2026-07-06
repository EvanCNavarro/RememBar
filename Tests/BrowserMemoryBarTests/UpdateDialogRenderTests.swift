import AppKit
@testable import BrowserMemoryBar
import Foundation
import MacFaceKit
import SwiftUI
import Testing

/// Offscreen PNG renders of every update-flow state (now the shared MacFaceKit `UpdateDialog`, driven
/// with RememBar's name + icon) for visual review that the extraction is behavior-identical. Gated on
/// REMEMBAR_RENDER_DIR like the other render suites. Not pixel assertions.
@MainActor
@Suite("Update Dialog Render")
struct UpdateDialogRenderTests {
    private static let notes = [
        "Refreshed the About screen into a cleaner, more consistent card",
        "Polished the search bar so the clear and return buttons line up with the field",
        "Fixed the Settings window opening far too tall on the About tab"
    ]

    @Test("render all seven update states")
    func renderStates() throws {
        let name = RememBarPaths.appName
        try render(UpdateDialog.permission(appName: name, onAllow: {}, onDecline: {}), "update_permission.png")
        try render(UpdateDialog.available(appName: name, version: "0.2.0", currentVersion: "0.1.0",
                                          notes: Self.notes, notesExpanded: .constant(true),
                                          onInstall: {}, onRemindLater: {}), "update_available.png")
        try render(UpdateDialog.checking(onCancel: {}), "update_checking.png")
        try render(UpdateDialog.progress(appName: name, heading: "Downloading update…", version: "0.2.0",
                                         fraction: 0.62, onCancel: {}), "update_progress.png")
        try render(UpdateDialog.ready(appName: name, version: "0.2.0", onRestart: {}), "update_ready.png")
        try render(UpdateDialog.upToDate(appName: name, version: "0.2.0", onOK: {}), "update_uptodate.png")
        try render(UpdateDialog.error(message: "Couldn't reach the update server. Check your connection and try again.",
                                      onOK: {}), "update_error.png")
    }

    private func render(_ dialog: UpdateDialog, _ name: String) throws {
        let renderer = ImageRenderer(content: GalleryDialogFrame { dialog.icon(rememBarUpdateIcon) })
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        guard let dir = ProcessInfo.processInfo.environment["REMEMBAR_RENDER_DIR"] else { return }
        try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
    }
}
