@testable import BrowserMemoryBar
import Foundation
import Testing

@Suite("Composite — alias liveness")
struct CompositeAliasLivenessTests {
    /// Thread-safe recorder for the aliases the composite hands the factory each search.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _families: [[[String]]] = []
        func record(_ families: [[String]]) { lock.lock(); _families.append(families); lock.unlock() }
        var callCount: Int { lock.lock(); defer { lock.unlock() }; return _families.count }
        var last: [[String]]? { lock.lock(); defer { lock.unlock() }; return _families.last }
    }

    private struct EmptyProvider: MemorySearching {
        func searchResponse(query: String, refinements: [String], limit: Int) async -> MemorySearchResponse {
            MemorySearchResponse()
        }
    }

    private func tempURL() throws -> (URL, () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir.appendingPathComponent("aliases.json"), { try? FileManager.default.removeItem(at: dir) })
    }

    @Test("composite reads catalog snapshot per search — an update is live on the next search, no rebuild")
    func livePerSearch() async throws {
        let (url, cleanup) = try tempURL(); defer { cleanup() }
        let catalog = AliasCatalog(url: url)
        let recorder = Recorder()
        let composite = CompositeMemorySearchProvider(
            catalog: catalog,
            providerFactory: { aliases in
                recorder.record(aliases.families)
                return [EmptyProvider()]
            }
        )

        _ = await composite.searchResponse(query: "x", refinements: [], limit: 5)
        #expect(recorder.last == []) // no families yet

        catalog.update(families: [["evan", "ecn"]]) // edit between searches — NO composite rebuild

        _ = await composite.searchResponse(query: "x", refinements: [], limit: 5)
        #expect(recorder.last == [["evan", "ecn"]]) // the SAME composite sees the update
        #expect(recorder.callCount == 2)
    }

    @Test("injected static providers bypass the catalog/factory entirely")
    func staticProvidersBypassCatalog() async throws {
        let (url, cleanup) = try tempURL(); defer { cleanup() }
        let recorder = Recorder()
        let composite = CompositeMemorySearchProvider(
            providers: [EmptyProvider()],
            catalog: AliasCatalog(url: url),
            providerFactory: { aliases in recorder.record(aliases.families); return [EmptyProvider()] }
        )
        _ = await composite.searchResponse(query: "x", refinements: [], limit: 5)
        #expect(recorder.callCount == 0) // factory never consulted when static providers are injected
    }
}
