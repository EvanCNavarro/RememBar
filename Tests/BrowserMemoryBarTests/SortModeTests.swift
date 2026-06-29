@testable import BrowserMemoryBar
import Foundation
import Testing

@Suite struct SortModeTests {
    /// Three file results in rank order a, b, c with modification dates b > a > c.
    private struct DatedProvider: MemorySearching {
        func searchResponse(query: String, refinements: [String], limit: Int) async -> MemorySearchResponse {
            let a = MemoryResult(fileURL: URL(fileURLWithPath: "/x/a.txt"), displayPath: "a.txt",
                                 modifiedAt: Date(timeIntervalSince1970: 2_000), rank: 100)
            let b = MemoryResult(fileURL: URL(fileURLWithPath: "/x/b.txt"), displayPath: "b.txt",
                                 modifiedAt: Date(timeIntervalSince1970: 3_000), rank: 90)
            let c = MemoryResult(fileURL: URL(fileURLWithPath: "/x/c.txt"), displayPath: "c.txt",
                                 modifiedAt: Date(timeIntervalSince1970: 1_000), rank: 80)
            return MemorySearchResponse(results: [a, b, c])
        }
    }

    @Test func toggleReordersBetweenRelevanceAndRecency() async {
        let store = await MainActor.run { MemorySearchStore(searchProvider: DatedProvider(), pageSize: 5) }
        await MainActor.run {
            store.inputText = "x"
            store.submit()
        }
        let ready = await eventually {
            await MainActor.run { store.phase == .results && store.results.count == 3 }
        }
        #expect(ready)

        // Relevance (default) preserves the provider's order.
        let relevance = await MainActor.run { (store.sortMode, store.results.map(\.title)) }
        #expect(relevance.0 == .relevance)
        #expect(relevance.1 == ["a.txt", "b.txt", "c.txt"])

        // Most recent: newest date first (b=3000, a=2000, c=1000).
        await MainActor.run { store.setSortMode(.recent) }
        let recent = await MainActor.run { (store.sortMode, store.results.map(\.title)) }
        #expect(recent.0 == .recent)
        #expect(recent.1 == ["b.txt", "a.txt", "c.txt"])

        // Back to relevance restores the provider's order.
        await MainActor.run { store.setSortMode(.relevance) }
        let back = await MainActor.run { store.results.map(\.title) }
        #expect(back == ["a.txt", "b.txt", "c.txt"])
    }
}
