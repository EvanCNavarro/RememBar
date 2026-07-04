import AppKit
@testable import BrowserMemoryBar
import Foundation
import SwiftUI
import Testing

/// Offscreen PNG renders of the term-families editor for visual review — not pixel assertions.
/// Gated on REMEMBAR_RENDER_DIR like PanelRenderTests.
@MainActor
@Suite("Alias Editor Render")
struct AliasEditorRenderTests {
    private func catalog(_ families: [[String]]) throws -> AliasCatalog {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("aliases.json")
        let cat = AliasCatalog(url: url)
        cat.update(families: families)
        return cat
    }

    @Test("render the term-families editor (populated, half-built, empty)")
    func renderEditor() throws {
        // Populated + a deliberately half-built (1-word) family to show the inactive hint. The
        // half-built row must be added via the model so it lives in the draft (not the sanitized set).
        let populated = AliasEditorModel(catalog: try catalog([["evan", "ecn", "navarro"], ["mom", "mother"]]))
        let solo = populated.addRow()
        populated.addWord("bluebox", toRow: solo)
        try render(AliasEditorView(model: populated).frame(width: 460, height: 380), to: "alias_editor.png")

        let empty = AliasEditorModel(catalog: try catalog([]))
        try render(AliasEditorView(model: empty).frame(width: 460, height: 380), to: "alias_editor_empty.png")

        // The tabbed settings window (Term Families tab + the toolbar-style tab bar).
        let settingsCatalog = try catalog([["evan", "ecn", "navarro"], ["mom", "mother"]])
        try render(
            SettingsRootView(catalog: settingsCatalog, onCheckForUpdates: {}, onUninstall: {})
                .frame(width: 480, height: 460),
            to: "settings_window.png"
        )
    }

    private func render(_ view: some View, to name: String) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        guard let dir = ProcessInfo.processInfo.environment["REMEMBAR_RENDER_DIR"] else { return }
        try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
    }
}
