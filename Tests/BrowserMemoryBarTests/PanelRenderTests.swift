import AppKit
@testable import BrowserMemoryBar
import Foundation
import SwiftUI
import Testing

private struct FixedResponseProvider: MemorySearching {
    let response: MemorySearchResponse
    func searchResponse(query: String, refinements: [String], limit: Int) async -> MemorySearchResponse {
        response
    }
}

/// Never returns within a render window — used to capture the real .loading (skeleton) state.
private struct SlowProvider: MemorySearching {
    func searchResponse(query: String, refinements: [String], limit: Int) async -> MemorySearchResponse {
        try? await Task.sleep(for: .seconds(60))
        return MemorySearchResponse(results: [], sourceStatuses: [])
    }
}

@Suite("PanelRender")
struct PanelRenderTests {
    /// Renders the REAL production MemoryPanel offscreen to a PNG so the layout can be reviewed
    /// without driving the live menu-bar app. Not a pass/fail assertion of pixels — a visual proof.
    @MainActor
    @Test("render MemoryPanel (results + exceptions) to a PNG")
    func renderPanel() async throws {
        let results: [MemoryResult] = [
            MemoryResult(fileURL: URL(fileURLWithPath: "/Users/example/Downloads/sample-notes.md"),
                         displayPath: "Downloads/sample-notes.md",
                         modifiedAt: Date(timeIntervalSince1970: 1_800_000_000), rank: 90),
            MemoryResult(fileURL: URL(fileURLWithPath: "/Users/example/Documents/sample-script.txt"),
                         displayPath: "Documents/sample-script.txt",
                         modifiedAt: Date(timeIntervalSince1970: 1_790_000_000), rank: 70),
            // A sensitive-named file (the redaction/fallback-tile case) on a neutral path.
            MemoryResult(fileURL: URL(fileURLWithPath: "/Users/example/Downloads/recovery-codes.txt"),
                         displayPath: "Downloads/recovery-codes.txt",
                         modifiedAt: Date(timeIntervalSince1970: 1_780_000_000), rank: 50)
        ]
        let statuses: [MemorySearchSourceStatus] = [
            MemorySearchSourceStatus(
                id: "files", sourceName: "Files", state: .failed, detail: "Could not read this source"),
            MemorySearchSourceStatus(
                id: "safari", sourceName: "Safari", state: .blocked, detail: "Permission required"),
            MemorySearchSourceStatus(
                id: MemorySearchSourceStatus.onePasswordID, sourceName: "1Password",
                state: .blocked, detail: "Unlock or sign in to 1Password"),
            MemorySearchSourceStatus(id: "chrome", sourceName: "Chrome", state: .searched, detail: "522 visits")
        ]
        let store = MemorySearchStore(
            searchProvider: FixedResponseProvider(
                response: MemorySearchResponse(results: results, sourceStatuses: statuses))
        )
        store.inputText = "sample"
        store.submit()
        var waited = 0
        while store.results.isEmpty, waited < 100 {
            try await Task.sleep(for: .milliseconds(50))
            waited += 1
        }
        #expect(!store.results.isEmpty)
        #expect(store.sourceStatuses.contains { $0.state == .blocked })

        try render(MemoryPanel(store: store).frame(width: 420).background(Tokens.panel),
                   to: "panel_render.png")
        try render(AboutPopover(onCheckForUpdates: {}, onUninstall: {}).fixedSize(),
                   to: "panel_about.png")
        try render(AboutPopover(onCheckForUpdates: {}, onUninstall: {}, showingActions: true).fixedSize(),
                   to: "panel_about_actions.png")

        // Empty — the real default panel (just the field + its actual placeholder, no invented copy).
        let emptyStore = MemorySearchStore(
            searchProvider: FixedResponseProvider(response: MemorySearchResponse(results: [], sourceStatuses: []))
        )
        try render(MemoryPanel(store: emptyStore).frame(width: 420).background(Tokens.panel),
                   to: "panel_empty.png")

        // Loading — submit against a never-returning provider, render while phase == .loading.
        let loadingStore = MemorySearchStore(searchProvider: SlowProvider())
        loadingStore.inputText = "linkedin"
        loadingStore.submit()
        try render(MemoryPanel(store: loadingStore).frame(width: 420).background(Tokens.panel),
                   to: "panel_loading.png")
    }

    @MainActor
    private func render(_ view: some View, to name: String) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        // Render to disk only when explicitly requested (dev visual review), into a neutral temp
        // dir — never a hardcoded personal/machine path.
        guard let dir = ProcessInfo.processInfo.environment["REMEMBAR_RENDER_DIR"] else { return }
        try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
    }
}
