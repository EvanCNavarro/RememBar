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

/// Returns results on the first search, then hangs — so the panel can be frozen mid *re-search* with
/// results still on screen (`isSearching == true`) to capture the dim + spinner feedback.
private final class ResultsThenHangProvider: MemorySearching, @unchecked Sendable {
    let response: MemorySearchResponse
    private let lock = NSLock()
    private var calls = 0
    init(response: MemorySearchResponse) { self.response = response }
    func searchResponse(query: String, refinements: [String], limit: Int) async -> MemorySearchResponse {
        let callNumber = lock.withLock { calls += 1; return calls }
        if callNumber > 1 { try? await Task.sleep(for: .seconds(60)) }
        return response
    }
}

@Suite("PanelRender")
struct PanelRenderTests {
    /// Renders the REAL production MemoryPanel offscreen to a PNG so the layout can be reviewed
    /// without driving the live menu-bar app. Not a pass/fail assertion of pixels — a visual proof.
    @MainActor
    @Test("render MemoryPanel (results + exceptions) to a PNG")
    // A visual-proof harness that renders many panel states in sequence — length is inherent.
    // swiftlint:disable:next function_body_length
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
        try render(AboutTab(onCheckForUpdates: {}, onUninstall: {}).frame(width: 480, height: 420),
                   to: "settings_about.png")

        // Empty — the real default panel (just the field + its actual placeholder, no invented copy).
        let emptyStore = MemorySearchStore(
            searchProvider: FixedResponseProvider(response: MemorySearchResponse(results: [], sourceStatuses: []))
        )
        try render(MemoryPanel(store: emptyStore).frame(width: 420).background(Tokens.panel),
                   to: "panel_empty.png")

        // Header controls — the settings gear (Term Families) sits next to the About "?" only when
        // the manage-families action is wired. Proves the two-icon layout + separation from "help".
        let gearStore = MemorySearchStore(
            searchProvider: FixedResponseProvider(response: MemorySearchResponse(results: [], sourceStatuses: []))
        )
        try render(
            MemoryPanel(store: gearStore, onOpenSettings: {})
                .frame(width: 420).background(Tokens.panel),
            to: "panel_gear.png"
        )

        // Loading — submit against a never-returning provider, render while phase == .loading.
        let loadingStore = MemorySearchStore(searchProvider: SlowProvider())
        loadingStore.inputText = "linkedin"
        loadingStore.submit()
        try render(MemoryPanel(store: loadingStore).frame(width: 420).background(Tokens.panel),
                   to: "panel_loading.png")

        // Re-searching over existing results — the state that used to look frozen: results stay but
        // dim, and the bar shows a spinner (isSearching == true).
        let researchStore = MemorySearchStore(
            searchProvider: ResultsThenHangProvider(
                response: MemorySearchResponse(results: results, sourceStatuses: []))
        )
        researchStore.inputText = "web"
        researchStore.submit()
        var w1 = 0
        while researchStore.results.isEmpty, w1 < 100 { try await Task.sleep(for: .milliseconds(50)); w1 += 1 }
        researchStore.inputText = "web apps"   // triggers the hanging second search
        researchStore.submit()
        var w2 = 0
        while !researchStore.isSearching, w2 < 100 { try await Task.sleep(for: .milliseconds(50)); w2 += 1 }
        #expect(researchStore.isSearching && !researchStore.results.isEmpty)
        try render(MemoryPanel(store: researchStore).frame(width: 420).background(Tokens.panel),
                   to: "panel_researching.png")

        // No results — a completed search that found nothing (the distinct showsNoResults state).
        let noResultsStore = MemorySearchStore(
            searchProvider: FixedResponseProvider(response: MemorySearchResponse(results: [], sourceStatuses: []))
        )
        noResultsStore.inputText = "zzzznotfound"
        noResultsStore.submit()
        var noResultsWaited = 0
        while !noResultsStore.showsNoResults, noResultsWaited < 100 {
            try await Task.sleep(for: .milliseconds(50))
            noResultsWaited += 1
        }
        #expect(noResultsStore.showsNoResults)
        try render(MemoryPanel(store: noResultsStore).frame(width: 420).background(Tokens.panel),
                   to: "panel_no_results.png")
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
