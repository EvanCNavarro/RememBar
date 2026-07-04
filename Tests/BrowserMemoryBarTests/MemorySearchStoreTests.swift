import AppKit
@testable import BrowserMemoryBar
import Foundation
import SQLite3
import Testing

@Suite("Memory Search Store")
struct MemorySearchStoreTests {
    @Test("sample search returns five initial results")
    func sampleSearchInitialResults() async {
        let provider = SampleMemorySearchProvider()

        let results = await provider.search(query: "web apps", refinements: [], limit: 5)

        #expect(results.map(\.id) == MemoryResult.initialRanking)
        #expect(results.first?.detail == "Browser · recently · sample, demo")
    }

    @Test("sample search applies refined ranking and metadata")
    func sampleSearchRefinedResults() async {
        let provider = SampleMemorySearchProvider()

        let results = await provider.search(query: "web apps", refinements: ["ship studio"], limit: 5)

        #expect(results.map(\.id) == MemoryResult.refinedRanking)
        #expect(results.first?.detail == "Best match · sample transcript keywords")
    }

    @Test("memory search store runs provider search off the main thread")
    func memorySearchStoreRunsProviderSearchOffMainThread() async throws {
        let provider = ThreadRecordingSearchProvider()
        let store = await MainActor.run {
            MemorySearchStore(searchProvider: provider)
        }

        await MainActor.run {
            store.inputText = "knucks son of a gun"
            store.submit()
        }

        let didRun = await eventually { provider.didRun }

        #expect(didRun)
        #expect(provider.ranOnMainThread == false)
    }

    @Test("memory search store treats each submitted ramble as a fresh search")
    // Verbose end-to-end setup + assertions for a multi-submit scenario; splitting would obscure it.
    // swiftlint:disable:next function_body_length
    func memorySearchStoreTreatsEachSubmittedRambleAsFreshSearch() async throws {
        let provider = RequestRecordingSearchProvider()
        let directory = try temporaryDirectory().appendingPathComponent("Diagnostics", isDirectory: true)
        let diagnostics = RememBarDiagnostics(
            directory: directory,
            sessionID: "ramble-submit",
            now: IncrementingClock(start: Date(timeIntervalSince1970: 1_800_001_000)).nextDate,
            processID: 556,
            maxLogBytes: 200_000
        )
        _ = diagnostics.startSession()
        let store = await MainActor.run {
            MemorySearchStore(searchProvider: provider, diagnostics: diagnostics)
        }

        await MainActor.run {
            store.inputText = "web apps"
            store.submit()
        }
        let firstSearchFinished = await eventually {
            await MainActor.run {
                store.phase == .results &&
                    store.baseQuery == "web apps" &&
                    store.refinements.isEmpty &&
                    store.results.isEmpty == false
            }
        }
        try #require(firstSearchFinished)
        #expect(provider.requests == [
            .init(query: "web apps", refinements: [])
        ])

        await MainActor.run {
            #expect(store.prompt == "Search files and history")
            #expect(store.phaseLabel == "Searched")
            #expect(store.contextValue == "web apps")
        }

        await MainActor.run {
            store.inputText = "ship studio"
            store.submit()
        }
        let secondSearchFinished = await eventually {
            await MainActor.run {
                store.phase == .results &&
                    store.baseQuery == "ship studio" &&
                    store.refinements.isEmpty &&
                    store.results.isEmpty == false
            }
        }
        try #require(secondSearchFinished)
        #expect(provider.requests == [
            .init(query: "web apps", refinements: []),
            .init(query: "ship studio", refinements: [])
        ])
        let submitEvents = try diagnosticEvents(at: diagnostics.logURL)
            .filter { $0.name == RememBarDiagnosticEvent.searchSubmit }
        #expect(submitEvents.count == 2)
        #expect(submitEvents.last?.fields["query"] == "ship studio")
        #expect(submitEvents.last?.fields["isRefinement"] == "false")
        #expect(submitEvents.last?.fields["refinementCount"] == "0")
        #expect(submitEvents.last?.fields["previousRefinementCount"] == "0")
        #expect(submitEvents.last?.fields["previousPhase"] == "results")
        #expect(submitEvents.last?.fields["submitPhase"] == "results")

        await MainActor.run {
            #expect(store.phase == .results)
            #expect(store.baseQuery == "ship studio")
            #expect(store.refinements.isEmpty)
            #expect(store.results.isEmpty == false)

            store.clearSearch()

            #expect(store.phase == .idle)
            #expect(store.inputText.isEmpty)
            #expect(store.baseQuery.isEmpty)
            #expect(store.refinements.isEmpty)
            #expect(store.results.isEmpty)
            #expect(store.selectedID == nil)
        }
    }

    @Test("submitting keeps the query in the field and gates the context line until edited")
    func submitKeepsQueryInFieldUntilEdited() async throws {
        let provider = RequestRecordingSearchProvider()
        let store = await MainActor.run { MemorySearchStore(searchProvider: provider) }

        await MainActor.run {
            store.inputText = "web apps"
            store.submit()
        }
        let finished = await eventually {
            await MainActor.run { store.phase == .results && store.results.isEmpty == false }
        }
        try #require(finished)

        await MainActor.run {
            // The submitted query stays in the field (no clear-on-submit) — visible + editable.
            #expect(store.inputText == "web apps")
            #expect(store.baseQuery == "web apps")
            // Context line hidden while the field matches the shown results' query (no duplicate).
            #expect(store.showsResultsQuery == false)
            // Editing the field away from that query surfaces the "Searched X" context again.
            store.inputText = "web apps pro"
            #expect(store.showsResultsQuery == true)
        }
    }

    @Test("memory search store exposes source statuses from response")
    func memorySearchStoreExposesSourceStatuses() async throws {
        let provider = StaticResponseMemorySearchProvider(response: MemorySearchResponse(
            results: [MemoryResult.samples["workflow"]!],
            sourceStatuses: [
                MemorySearchSourceStatus(
                    id: "safari",
                    sourceName: "Safari",
                    state: .blocked,
                    detail: "Authorization denied"
                )
            ]
        ))
        let store = await MainActor.run {
            MemorySearchStore(searchProvider: provider)
        }

        await MainActor.run {
            store.inputText = "facebook recovery codes"
            store.submit()
        }
        let finished = await eventually {
            await MainActor.run {
                store.phase == .results && store.sourceStatuses.first?.id == "safari"
            }
        }

        try #require(finished)
        await MainActor.run {
            #expect(store.sourceStatuses.first?.state == .blocked)
        }
    }

    @Test("memory search store pages through fetched results")
    func memorySearchStorePagesThroughFetchedResults() async throws {
        let ordered = MemoryResult.initialRanking.compactMap { MemoryResult.samples[$0] }
        let provider = StaticResponseMemorySearchProvider(response: MemorySearchResponse(results: ordered))
        let store = await MainActor.run {
            MemorySearchStore(searchProvider: provider, pageSize: 2, resultFetchLimit: 5)
        }

        await MainActor.run {
            store.inputText = "web apps"
            store.submit()
        }
        let firstPageLoaded = await eventually {
            await MainActor.run {
                store.phase == .results && store.results.map(\.id) == ["workflow", "claude-design"]
            }
        }

        try #require(firstPageLoaded)
        await MainActor.run {
            #expect(store.pageLabel == "1 of 3")
            #expect(store.canGoToNextPage)
            #expect(!store.canGoToPreviousPage)

            store.goToNextPage()
            #expect(store.results.map(\.id) == ["codex-prototypes", "landing-pages"])
            #expect(store.pageLabel == "2 of 3")
            #expect(store.canGoToNextPage)
            #expect(store.canGoToPreviousPage)

            store.goToNextPage()
            #expect(store.results.map(\.id) == ["faster-claude"])
            #expect(store.pageLabel == "3 of 3")
            #expect(!store.canGoToNextPage)

            store.goToPreviousPage()
            #expect(store.results.map(\.id) == ["codex-prototypes", "landing-pages"])
        }
    }

    @Test("arrow-down highlights the first result, walks down, and advances a page at the boundary")
    func keyboardDownWalksAndPages() async throws {
        let ordered = MemoryResult.initialRanking.compactMap { MemoryResult.samples[$0] }
        let store = await MainActor.run {
            MemorySearchStore(
                searchProvider: StaticResponseMemorySearchProvider(response: MemorySearchResponse(results: ordered)),
                pageSize: 2, resultFetchLimit: 5
            )
        }
        await MainActor.run { store.inputText = "web apps"; store.submit() }
        _ = await eventually { await MainActor.run { store.results.map(\.id) == ["workflow", "claude-design"] } }
        await MainActor.run {
            #expect(store.selectedID == nil)
            store.moveSelectionDown()
            #expect(store.selectedID == "workflow")          // none -> first
            store.moveSelectionDown()
            #expect(store.selectedID == "claude-design")     // walks down within the page
            store.moveSelectionDown()
            #expect(store.results.map(\.id) == ["codex-prototypes", "landing-pages"]) // crossed to page 2
            #expect(store.selectedID == "codex-prototypes")  // first of the new page
        }
    }

    @Test("arrow-up stops at the very top (no wrap)")
    func keyboardUpStopsAtTop() async throws {
        let ordered = MemoryResult.initialRanking.compactMap { MemoryResult.samples[$0] }
        let store = await MainActor.run {
            MemorySearchStore(
                searchProvider: StaticResponseMemorySearchProvider(response: MemorySearchResponse(results: ordered)),
                pageSize: 2, resultFetchLimit: 5
            )
        }
        await MainActor.run { store.inputText = "web apps"; store.submit() }
        _ = await eventually { await MainActor.run { !store.results.isEmpty } }
        await MainActor.run {
            store.moveSelectionDown()                        // -> workflow (top)
            #expect(store.selectedID == "workflow")
            store.moveSelectionUp()                          // at top, page 1 -> no wrap, stays
            #expect(store.selectedID == "workflow")
            #expect(!store.canGoToPreviousPage)              // still on the first page
        }
    }

    @Test("Enter opens the highlighted/top result when results match; searches when the query is stale")
    func enterOpensOrSearches() async throws {
        let opener = RecordingMemoryResultOpener()
        let ordered = MemoryResult.initialRanking.compactMap { MemoryResult.samples[$0] }
        let store = await MainActor.run {
            MemorySearchStore(
                searchProvider: StaticResponseMemorySearchProvider(response: MemorySearchResponse(results: ordered)),
                resultOpener: opener, pageSize: 2, resultFetchLimit: 5
            )
        }
        await MainActor.run { store.inputText = "web apps"; store.submit() }
        _ = await eventually { await MainActor.run { store.resultsQuery == "web apps" && !store.results.isEmpty } }
        await MainActor.run {
            // No highlight yet + matching results -> Enter opens the TOP result.
            store.submitOrOpen()
            #expect(opener.opened.map(\.id) == ["workflow"])
            // Override the text (stale) -> Enter searches, does NOT open a stale row.
            store.inputText = "somethingelse"
            store.submitOrOpen()
            #expect(opener.opened.map(\.id) == ["workflow"]) // unchanged
            #expect(store.baseQuery == "somethingelse")      // a search was dispatched instead
        }
    }

    @Test("memory search store clear cancels loading search")
    func memorySearchStoreClearCancelsLoadingSearch() async throws {
        let store = await MainActor.run {
            MemorySearchStore(searchProvider: SampleMemorySearchProvider())
        }

        await MainActor.run {
            store.inputText = "web apps"
            store.submit()
            store.clearSearch()
        }
        // clearSearch cancels the debounced task synchronously, so the store settles to idle at
        // once — no fixed wait (nothing to race).
        await MainActor.run {
            #expect(store.phase == .idle)
            #expect(store.results.isEmpty)
            #expect(store.baseQuery.isEmpty)
        }
    }
}
