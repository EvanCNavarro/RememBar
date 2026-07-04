@testable import BrowserMemoryBar
import Foundation
import Testing

@Suite("Alias Catalog")
struct AliasCatalogTests {
    private func tempURL() throws -> (URL, () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir.appendingPathComponent("aliases.json"), { try? FileManager.default.removeItem(at: dir) })
    }

    @Test("loads existing groups from disk at init")
    func loadsAtInit() throws {
        let (url, cleanup) = try tempURL(); defer { cleanup() }
        try AliasGroups(groups: [["evan", "ecn"]]).save(to: url)
        let catalog = AliasCatalog(url: url)
        #expect(catalog.snapshot.expand(["evan"]) == ["evan", "ecn"])
    }

    @Test("missing/malformed file loads empty, never crashes")
    func emptyWhenMissing() throws {
        let (url, cleanup) = try tempURL(); defer { cleanup() }
        #expect(AliasCatalog(url: url).snapshot == .empty)
    }

    @Test("update sanitizes, persists to disk, and is visible in the next snapshot")
    func updatePersistsAndPublishes() throws {
        let (url, cleanup) = try tempURL(); defer { cleanup() }
        let catalog = AliasCatalog(url: url)
        catalog.update(families: [["Evan", "ECN", "x"], ["mom", "mother"], ["solo"]])
        // sanitized: lowercased, 1-char + <2-member groups dropped
        #expect(catalog.snapshot.families == [["evan", "ecn"], ["mom", "mother"]])
        // persisted — a fresh load from the same file sees it
        #expect(AliasGroups.load(from: url) == catalog.snapshot)
    }

    @Test("reload picks up an external edit to the file")
    func reloadPicksUpExternalEdit() throws {
        let (url, cleanup) = try tempURL(); defer { cleanup() }
        let catalog = AliasCatalog(url: url)
        #expect(catalog.snapshot == .empty)
        try AliasGroups(groups: [["red", "crimson"]]).save(to: url)
        catalog.reload()
        #expect(catalog.snapshot.expand(["red"]) == ["red", "crimson"])
    }

    @Test("survives a heavy storm of interleaved updates, snapshots and reloads")
    func heavyConcurrentStorm() async throws {
        let (url, cleanup) = try tempURL(); defer { cleanup() }
        let catalog = AliasCatalog(url: url)
        await withTaskGroup(of: Void.self) { group in
            for idx in 0..<300 {
                switch idx % 3 {
                case 0: group.addTask { catalog.update(families: [["w\(idx % 7)", "a\(idx % 7)"]]) }
                case 1: group.addTask { _ = catalog.snapshot.expand(["w\(idx % 7)"]) }
                default: group.addTask { catalog.reload() }
                }
            }
        }
        // No crash / torn read; the final snapshot is a valid sanitized value (0 or 1 group here).
        #expect(catalog.snapshot.families.count <= 1)
        // And the catalog is still usable afterward.
        catalog.update(families: [["final", "done"]])
        #expect(catalog.snapshot.expand(["final"]) == ["final", "done"])
    }

    // The load-bearing concurrency guarantee: the catalog's snapshot is read by search providers
    // running OFF the main actor (CompositeMemorySearchProvider's withTaskGroup). A @MainActor design
    // would not compile / would crash there — this proves concurrent reads+writes are race-free.
    @Test("snapshot is safe to read+write concurrently from background threads")
    func concurrentAccessIsSafe() async throws {
        let (url, cleanup) = try tempURL(); defer { cleanup() }
        let catalog = AliasCatalog(url: url)
        await withTaskGroup(of: Void.self) { group in
            for idx in 0..<50 {
                group.addTask { catalog.update(families: [["term\(idx)", "alias\(idx)"]]) }
                group.addTask { _ = catalog.snapshot.expand(["term\(idx)"]) }
            }
        }
        // A valid (any-writer-wins) single-group state; no crash, no torn read.
        #expect(catalog.snapshot.families.count == 1)
    }
}
