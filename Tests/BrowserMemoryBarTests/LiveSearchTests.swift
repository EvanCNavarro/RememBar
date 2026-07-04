@testable import BrowserMemoryBar
import Foundation
import Testing

/// P1a — live-as-you-type: typing dispatches a debounced search through the SAME single pipeline as
/// Enter (which bypasses the debounce), results are replaced (not blanked) while revalidating, empty
/// input returns to idle, and a too-short live query does not fire.
@Suite("Live Search")
struct LiveSearchTests {
    private func sampleResult() -> MemoryResult {
        MemoryResult(fileURL: URL(fileURLWithPath: "/Users/x/Downloads/web-apps.md"),
                     displayPath: "Downloads/web-apps.md",
                     modifiedAt: Date(timeIntervalSince1970: 1_800_000_000), rank: 90)
    }

    @Test("typing dispatches a debounced search through the shared pipeline")
    func typingDispatchesDebouncedSearch() async {
        let provider = RequestRecordingSearchProvider()
        let store = await MainActor.run {
            MemorySearchStore(searchProvider: provider, searchDebounce: .milliseconds(5))
        }
        await MainActor.run { store.inputText = "web apps"; store.inputChanged() }
        let ran = await eventually { provider.requests.contains { $0.query == "web apps" } }
        #expect(ran)
    }

    @Test("rapid typing coalesces — only the latest query actually searches")
    func rapidTypingCoalesces() async {
        let provider = RequestRecordingSearchProvider()
        let store = await MainActor.run {
            MemorySearchStore(searchProvider: provider, searchDebounce: .milliseconds(40))
        }
        await MainActor.run {
            for fragment in ["w", "we", "web", "web ", "web a", "web ap", "web app", "web apps"] {
                store.inputText = fragment
                store.inputChanged()
            }
        }
        let settled = await eventually { provider.requests.contains { $0.query == "web apps" } }
        #expect(settled)
        // Every earlier fragment's debounce was cancelled by the next keystroke — none reached the provider.
        #expect(provider.requests.allSatisfy { $0.query == "web apps" })
    }

    @Test("Enter bypasses the debounce entirely (searches immediately)")
    func enterBypassesDebounce() async {
        // A 10s debounce would make a *typed* search hang; Enter must resolve fast regardless.
        let store = await MainActor.run {
            MemorySearchStore(
                searchProvider: StaticMemorySearchProvider(results: [sampleResult()]),
                searchDebounce: .seconds(10)
            )
        }
        await MainActor.run { store.inputText = "web apps"; store.submit() }
        let finished = await eventually {
            await MainActor.run { store.phase == .results && !store.results.isEmpty }
        }
        #expect(finished)
    }

    @Test("stale-while-revalidate: results are not blanked when a new search dispatches")
    func staleResultsRetainedDuringRevalidate() async {
        let store = await MainActor.run {
            MemorySearchStore(searchProvider: StaticMemorySearchProvider(results: [sampleResult()]))
        }
        await MainActor.run { store.inputText = "web"; store.submit() }
        _ = await eventually {
            await MainActor.run { store.phase == .results && !store.results.isEmpty }
        }
        // Dispatch a new search; results must remain visible (not cleared) until the new response lands.
        let retained = await MainActor.run { () -> Bool in
            store.inputText = "web apps"
            store.submit()
            return !store.results.isEmpty // SWR invariant: no blank-on-dispatch
        }
        #expect(retained)
    }

    @Test("clearing the input returns the store to idle")
    func emptyInputResetsToIdle() async {
        let store = await MainActor.run {
            MemorySearchStore(searchProvider: StaticMemorySearchProvider(results: [sampleResult()]))
        }
        await MainActor.run { store.inputText = "web apps"; store.submit() }
        _ = await eventually { await MainActor.run { store.phase == .results } }
        let idle = await MainActor.run { () -> Bool in
            store.inputText = ""
            store.inputChanged()
            return store.phase == .idle && store.results.isEmpty
        }
        #expect(idle)
    }

    @Test("a too-short live query does not dispatch (Enter still would)")
    func shortLiveQueryDoesNotDispatch() async throws {
        let provider = RequestRecordingSearchProvider()
        let store = await MainActor.run {
            MemorySearchStore(searchProvider: provider, searchDebounce: .milliseconds(5))
        }
        await MainActor.run { store.inputText = "e"; store.inputChanged() }
        try await Task.sleep(for: .milliseconds(80))
        #expect(provider.requests.isEmpty)
    }

    @Test("deleting to a sub-threshold query during a cold search never strands the loading state")
    func subThresholdDeleteClearsLoading() async {
        // A cold search sets phase = .loading; deleting to 1 char cancels it — the skeleton must not
        // be left running with no in-flight task (reviewer-reproduced blocking bug).
        let store = await MainActor.run {
            MemorySearchStore(
                searchProvider: StaticMemorySearchProvider(results: [sampleResult()]),
                searchDebounce: .seconds(10)
            )
        }
        let wasLoading = await MainActor.run { () -> Bool in
            store.inputText = "ab"; store.inputChanged()
            return store.phase == .loading
        }
        #expect(wasLoading)
        let recovered = await MainActor.run { () -> Bool in
            store.inputText = "a"; store.inputChanged()
            return store.phase == .idle
        }
        #expect(recovered)
    }

    @Test("re-entrant echo of the current query does not re-dispatch (retry/clear guard)")
    func echoOfCurrentQueryDoesNotRedispatch() async throws {
        // retry()/clearSearch() write inputText programmatically, which re-enters inputChanged() via
        // the field's onChange. An edit that doesn't change the effective query must not search again.
        let provider = RequestRecordingSearchProvider()
        let store = await MainActor.run {
            MemorySearchStore(searchProvider: provider, searchDebounce: .milliseconds(5))
        }
        await MainActor.run { store.inputText = "web apps"; store.submit() }
        _ = await eventually { await MainActor.run { store.phase == .results } }
        let baseline = provider.requests.count
        await MainActor.run { store.inputChanged() } // echo: inputText already == baseQuery
        try await Task.sleep(for: .milliseconds(60))
        #expect(provider.requests.count == baseline)
    }

    @Test("a lone whitespace keystroke does not wipe the field or clear an active search")
    func whitespaceDoesNotWipe() async {
        let store = await MainActor.run {
            MemorySearchStore(searchProvider: StaticMemorySearchProvider(results: [sampleResult()]))
        }
        await MainActor.run { store.inputText = "web"; store.submit() }
        _ = await eventually { await MainActor.run { store.phase == .results } }
        let kept = await MainActor.run { () -> Bool in
            store.inputText = "web "  // trailing space — same effective query
            store.inputChanged()
            return store.inputText == "web " && !store.results.isEmpty
        }
        #expect(kept)
    }

    @Test("a storm of keystrokes, submits and clears settles cleanly on the final query")
    func keystrokeStormSettles() async {
        let provider = RequestRecordingSearchProvider()
        let store = await MainActor.run {
            MemorySearchStore(searchProvider: provider, searchDebounce: .milliseconds(3))
        }
        // Hammer the single dispatch pipeline: partial types, interleaved clears + an Enter, then a
        // final distinct query. Must not crash / strand tasks, and must end on the final query.
        await MainActor.run {
            for round in 0..<40 {
                store.inputText = "q\(round)a"; store.inputChanged()
                store.inputText = "q\(round)ab"; store.inputChanged()
                if round % 5 == 0 { store.inputText = "force\(round)"; store.submit() }
                if round % 7 == 0 { store.inputText = ""; store.inputChanged() }
            }
            store.inputText = "finalquery"; store.submit()
        }
        let settled = await eventually { provider.requests.last?.query == "finalquery" }
        #expect(settled)
        let phaseOK = await MainActor.run { store.phase == .results && store.baseQuery == "finalquery" }
        #expect(phaseOK)
    }

    @Test("overriding the query over existing results signals isSearching, then clears")
    func revalidateSignalsSearchActivity() async {
        // A slow provider so the in-flight window is observable — this is the feedback that was missing
        // (results stayed on screen with NO indication a new search was running).
        let response = MemorySearchResponse(results: [sampleResult()], sourceStatuses: [])
        let store = await MainActor.run {
            MemorySearchStore(
                searchProvider: DelayedResponseMemorySearchProvider(delay: .milliseconds(150), response: response)
            )
        }
        await MainActor.run { store.inputText = "web"; store.submit() }
        _ = await eventually { await MainActor.run { store.phase == .results && !store.results.isEmpty } }
        let settledQuiet = await MainActor.run { !store.isSearching }
        #expect(settledQuiet)

        // Override the text — results stay (SWR) but isSearching must be true so the UI can show it.
        await MainActor.run { store.inputText = "different query"; store.submit() }
        let signalsWhileResultsShow = await eventually {
            await MainActor.run { store.isSearching && !store.results.isEmpty }
        }
        #expect(signalsWhileResultsShow)
        // And it clears once the search lands.
        let cleared = await eventually { await MainActor.run { !store.isSearching } }
        #expect(cleared)
    }

    @Test("results are marked stale the instant the field diverges — even below the search minimum")
    func resultsGoStaleImmediatelyOnDivergence() async {
        let store = await MainActor.run {
            MemorySearchStore(searchProvider: StaticMemorySearchProvider(results: [sampleResult()]))
        }
        await MainActor.run { store.inputText = "web"; store.submit() }
        _ = await eventually { await MainActor.run { store.phase == .results && !store.results.isEmpty } }
        // Fresh, matching results: not stale.
        let matching = await MainActor.run { store.resultsQuery == "web" && !store.resultsAreStale }
        #expect(matching)
        // Divergence is immediate — a single character (below the 2-char live minimum) already dims.
        let staleOnFirstChar = await MainActor.run { () -> Bool in
            store.inputText = "g"
            return store.resultsAreStale
        }
        #expect(staleOnFirstChar)
        // Typing back to the exact results' query clears the stale flag again.
        let unStale = await MainActor.run { () -> Bool in
            store.inputText = "web"
            return !store.resultsAreStale
        }
        #expect(unStale)
    }

    @Test("isSearching is false in idle, too-short and cleared states")
    func isSearchingFalseWhenNotSearching() async {
        let provider = RequestRecordingSearchProvider()
        let store = await MainActor.run {
            MemorySearchStore(searchProvider: provider, searchDebounce: .milliseconds(5))
        }
        let idle = await MainActor.run { !store.isSearching }
        #expect(idle)
        let tooShort = await MainActor.run { () -> Bool in
            store.inputText = "a"; store.inputChanged()
            return !store.isSearching
        }
        #expect(tooShort)
        let afterClear = await MainActor.run { () -> Bool in
            store.inputText = "web apps"; store.submit()
            store.clearSearch()
            return !store.isSearching
        }
        #expect(afterClear)
    }

    @Test("empty results land in a distinct no-results state")
    func noResultsDistinctState() async {
        let store = await MainActor.run {
            MemorySearchStore(searchProvider: StaticMemorySearchProvider(results: []))
        }
        await MainActor.run { store.inputText = "zzzznotfound"; store.submit() }
        let finished = await eventually { await MainActor.run { store.phase == .results } }
        #expect(finished)
        let noResults = await MainActor.run { store.results.isEmpty && store.showsNoResults }
        #expect(noResults)
    }
}
