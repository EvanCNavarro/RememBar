import Foundation
import AppKit
import SQLite3
import Testing
@testable import BrowserMemoryBar

@Suite("RememBar")
struct RememBarTests {
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

    @Test("diagnostics records session lifecycle and ordered JSON breadcrumbs")
    func diagnosticsRecordsSessionLifecycleAndOrderedJSONBreadcrumbs() throws {
        let directory = try temporaryDirectory().appendingPathComponent("Diagnostics", isDirectory: true)
        let clock = IncrementingClock(start: Date(timeIntervalSince1970: 1_800_000_000))
        let diagnostics = RememBarDiagnostics(
            directory: directory,
            sessionID: "session-a",
            now: clock.nextDate,
            processID: 4242,
            maxLogBytes: 200_000
        )

        let previous = diagnostics.startSession()
        diagnostics.record(
            "search.submit",
            fields: ["query": "alpha soccer card", "phase": "idle"],
            file: "Tests/Diagnostics.swift",
            function: "diagnosticsTest()",
            line: 77
        )
        diagnostics.endSession(reason: "test")

        #expect(previous == nil)

        let events = try diagnosticEvents(at: diagnostics.logURL)
        try #require(events.count == 3)
        #expect(events.map(\.name) == [
            "diagnostics.session.started",
            "search.submit",
            "diagnostics.session.ended"
        ])
        #expect(events.map(\.sequence) == [1, 2, 3])
        #expect(events[1].sessionID == "session-a")
        #expect(events[1].fields["query"] == "alpha soccer card")
        #expect(events[1].file == "Tests/Diagnostics.swift")
        #expect(events[1].line == 77)

        let state = try diagnosticState(at: diagnostics.stateURL)
        #expect(state["sessionID"] as? String == "session-a")
        #expect(state["cleanExit"] as? Bool == true)
        #expect(state["lastEventName"] as? String == "diagnostics.session.ended")
    }

    @Test("diagnostics async records eventually write JSON breadcrumbs")
    func diagnosticsAsyncRecordsEventuallyWriteJSONBreadcrumbs() async throws {
        let directory = try temporaryDirectory().appendingPathComponent("Diagnostics", isDirectory: true)
        let clock = IncrementingClock(start: Date(timeIntervalSince1970: 1_800_000_200))
        let diagnostics = RememBarDiagnostics(
            directory: directory,
            sessionID: "async-record-test",
            now: clock.nextDate,
            processID: 1235,
            maxLogBytes: 100_000
        )

        _ = diagnostics.startSession()
        diagnostics.recordAsync("async.event", fields: ["source": "test"])

        let events = await eventuallyDiagnosticEvents(at: diagnostics.logURL, prefix: "async.", count: 1)
        try #require(events.count == 1)
        #expect(events[0].fields["source"] == "test")
    }

    @Test("diagnostics sync records flush earlier async breadcrumbs before continuing")
    func diagnosticsSyncRecordsFlushEarlierAsyncBreadcrumbsBeforeContinuing() async throws {
        let directory = try temporaryDirectory().appendingPathComponent("Diagnostics", isDirectory: true)
        let clock = IncrementingClock(start: Date(timeIntervalSince1970: 1_800_000_250))
        let diagnostics = RememBarDiagnostics(
            directory: directory,
            sessionID: "async-order-test",
            now: clock.nextDate,
            processID: 1236,
            maxLogBytes: 100_000
        )

        _ = diagnostics.startSession()
        for index in 0..<20 {
            diagnostics.recordAsync("async.before", fields: ["index": "\(index)"])
        }
        diagnostics.record("sync.after")

        let events = await eventuallyDiagnosticEvents(at: diagnostics.logURL, prefix: "async.", count: 20)
        try #require(events.count == 20)
        let names = try diagnosticEvents(at: diagnostics.logURL).map(\.name)
        let syncIndex = try #require(names.firstIndex(of: "sync.after"))
        let lastAsyncIndex = try #require(names.lastIndex(of: "async.before"))
        #expect(lastAsyncIndex < syncIndex)
    }

    @Test("diagnostics end session drains queued async breadcrumbs before clean exit")
    func diagnosticsEndSessionDrainsQueuedAsyncBreadcrumbsBeforeCleanExit() async throws {
        let directory = try temporaryDirectory().appendingPathComponent("Diagnostics", isDirectory: true)
        let clock = IncrementingClock(start: Date(timeIntervalSince1970: 1_800_000_300))
        let diagnostics = RememBarDiagnostics(
            directory: directory,
            sessionID: "async-end-test",
            now: clock.nextDate,
            processID: 1237,
            maxLogBytes: 200_000
        )

        _ = diagnostics.startSession()
        for index in 0..<50 {
            diagnostics.recordAsync("async.before_end", fields: ["index": "\(index)"])
        }
        diagnostics.endSession(reason: "test")

        let events = await eventuallyDiagnosticEvents(at: diagnostics.logURL, prefix: "async.", count: 50)
        try #require(events.count == 50)
        let names = try diagnosticEvents(at: diagnostics.logURL).map(\.name)
        let endIndex = try #require(names.firstIndex(of: RememBarDiagnosticEvent.diagnosticsSessionEnded))
        let lastAsyncIndex = try #require(names.lastIndex(of: "async.before_end"))
        #expect(lastAsyncIndex < endIndex)
    }

    @Test("diagnostics reports previous unclean session with last breadcrumb")
    func diagnosticsReportsPreviousUncleanSessionWithLastBreadcrumb() throws {
        let directory = try temporaryDirectory().appendingPathComponent("Diagnostics", isDirectory: true)
        let clock = IncrementingClock(start: Date(timeIntervalSince1970: 1_800_000_100))
        let firstRun = RememBarDiagnostics(
            directory: directory,
            sessionID: "first-run",
            now: clock.nextDate,
            processID: 111,
            maxLogBytes: 200_000
        )
        _ = firstRun.startSession()
        firstRun.record("mdfind.process.launch", fields: ["query": "kMDItemFSName == '*alpha*'"])

        let secondRun = RememBarDiagnostics(
            directory: directory,
            sessionID: "second-run",
            now: clock.nextDate,
            processID: 222,
            maxLogBytes: 200_000
        )
        let previous = secondRun.startSession()

        #expect(previous?.sessionID == "first-run")
        #expect(previous?.lastEventName == "mdfind.process.launch")
        #expect(previous?.lastSequence == 2)

        let events = try diagnosticEvents(at: secondRun.logURL)
        let unclean = events.first { $0.name == "diagnostics.previous_session_unclean" }
        #expect(unclean?.fields["previousSessionID"] == "first-run")
        #expect(unclean?.fields["lastEventName"] == "mdfind.process.launch")
        #expect(unclean?.fields["lastSequence"] == "2")
    }

    @Test("diagnostics keeps previous state when first new session breadcrumb cannot be written")
    func diagnosticsKeepsPreviousStateWhenFirstNewSessionBreadcrumbCannotBeWritten() throws {
        let directory = try temporaryDirectory().appendingPathComponent("Diagnostics", isDirectory: true)
        let clock = IncrementingClock(start: Date(timeIntervalSince1970: 1_800_000_150))
        let firstRun = RememBarDiagnostics(
            directory: directory,
            sessionID: "first-run",
            now: clock.nextDate,
            processID: 232,
            maxLogBytes: 200_000
        )
        _ = firstRun.startSession()
        firstRun.record("search.started")
        try FileManager.default.removeItem(at: firstRun.logURL)
        try FileManager.default.createDirectory(at: firstRun.logURL, withIntermediateDirectories: false)

        let secondRun = RememBarDiagnostics(
            directory: directory,
            sessionID: "second-run",
            now: clock.nextDate,
            processID: 233,
            maxLogBytes: 200_000
        )
        _ = secondRun.startSession(crashReportScanner: EmptyCrashReportScanner())

        let state = try diagnosticState(at: secondRun.stateURL)
        #expect(state["sessionID"] as? String == "first-run")
        #expect(state["cleanExit"] as? Bool == false)
        #expect(state["lastEventName"] as? String == "search.started")
    }

    @Test("diagnostics clean exit from older process does not mark newer session clean")
    func diagnosticsCleanExitFromOlderProcessDoesNotMarkNewerSessionClean() throws {
        let directory = try temporaryDirectory().appendingPathComponent("Diagnostics", isDirectory: true)
        let clock = IncrementingClock(start: Date(timeIntervalSince1970: 1_800_000_175))
        let older = RememBarDiagnostics(
            directory: directory,
            sessionID: "older-process",
            now: clock.nextDate,
            processID: 242,
            maxLogBytes: 200_000
        )
        _ = older.startSession()
        let newer = RememBarDiagnostics(
            directory: directory,
            sessionID: "newer-process",
            now: clock.nextDate,
            processID: 243,
            maxLogBytes: 200_000
        )
        _ = newer.startSession()

        older.endSession(reason: "late-termination")

        let state = try diagnosticState(at: newer.stateURL)
        #expect(state["sessionID"] as? String == "newer-process")
        #expect(state["cleanExit"] as? Bool == false)
        #expect(state["lastEventName"] as? String == "diagnostics.session.started")
    }

    @Test("diagnostics keeps unique ordered sequences under concurrent writes")
    func diagnosticsKeepsUniqueOrderedSequencesUnderConcurrentWrites() async throws {
        let directory = try temporaryDirectory().appendingPathComponent("Diagnostics", isDirectory: true)
        let clock = IncrementingClock(start: Date(timeIntervalSince1970: 1_800_000_200))
        let diagnostics = RememBarDiagnostics(
            directory: directory,
            sessionID: "concurrent",
            now: clock.nextDate,
            processID: 333,
            maxLogBytes: 200_000
        )
        _ = diagnostics.startSession()

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<40 {
                group.addTask {
                    diagnostics.record("stress.event", fields: ["index": "\(index)"])
                }
            }
        }

        let events = try diagnosticEvents(at: diagnostics.logURL)
        #expect(events.count == 41)
        #expect(events.map(\.sequence) == Array(1...41))
        #expect(Set(events.map(\.sequence)).count == 41)
        #expect(events.filter { $0.name == "stress.event" }.count == 40)
    }

    @Test("diagnostics retention keeps recent breadcrumbs within byte budget")
    func diagnosticsRetentionKeepsRecentBreadcrumbsWithinByteBudget() throws {
        let directory = try temporaryDirectory().appendingPathComponent("Diagnostics", isDirectory: true)
        let clock = IncrementingClock(start: Date(timeIntervalSince1970: 1_800_000_300))
        let diagnostics = RememBarDiagnostics(
            directory: directory,
            sessionID: "retention",
            now: clock.nextDate,
            processID: 444,
            maxLogBytes: 1_800
        )
        _ = diagnostics.startSession()

        for index in 0..<30 {
            diagnostics.record(
                "retention.event",
                fields: [
                    "index": "\(index)",
                    "payload": String(repeating: "x", count: 120)
                ]
            )
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: diagnostics.logURL.path)
        let size = try #require(attributes[.size] as? NSNumber).intValue
        let events = try diagnosticEvents(at: diagnostics.logURL)

        #expect(size <= 1_800)
        #expect(events.last?.fields["index"] == "29")
        #expect(events.first?.sequence ?? 0 > 1)
    }

    @Test("diagnostics ignores late records after a clean session end")
    func diagnosticsIgnoresLateRecordsAfterCleanSessionEnd() throws {
        let directory = try temporaryDirectory().appendingPathComponent("Diagnostics", isDirectory: true)
        let clock = IncrementingClock(start: Date(timeIntervalSince1970: 1_800_000_350))
        let diagnostics = RememBarDiagnostics(
            directory: directory,
            sessionID: "late-records",
            now: clock.nextDate,
            processID: 445,
            maxLogBytes: 200_000
        )
        _ = diagnostics.startSession()
        diagnostics.record("search.started")
        diagnostics.endSession(reason: "test-clean")
        diagnostics.record("thumbnail.quicklook.finished", fields: ["path": "/tmp/late.psd"])

        let events = try diagnosticEvents(at: diagnostics.logURL)
        #expect(events.map(\.name) == [
            "diagnostics.session.started",
            "search.started",
            "diagnostics.session.ended"
        ])
        let state = try diagnosticState(at: diagnostics.stateURL)
        #expect(state["cleanExit"] as? Bool == true)
        #expect(state["lastEventName"] as? String == "diagnostics.session.ended")
    }

    @Test("diagnostics does not advance state when log writes fail")
    func diagnosticsDoesNotAdvanceStateWhenLogWritesFail() throws {
        let root = try temporaryDirectory()
        let directory = root.appendingPathComponent("Diagnostics", isDirectory: true)
        let clock = IncrementingClock(start: Date(timeIntervalSince1970: 1_800_000_360))
        let diagnostics = RememBarDiagnostics(
            directory: directory,
            sessionID: "write-failure",
            now: clock.nextDate,
            processID: 446,
            maxLogBytes: 200_000
        )
        _ = diagnostics.startSession()
        diagnostics.record("search.started")
        try FileManager.default.removeItem(at: diagnostics.logURL)
        try FileManager.default.createDirectory(at: diagnostics.logURL, withIntermediateDirectories: false)

        diagnostics.record("search.after.write.failure")

        let state = try diagnosticState(at: diagnostics.stateURL)
        #expect(state["cleanExit"] as? Bool == false)
        #expect(state["lastEventName"] as? String == "search.started")
        #expect(state["lastSequence"] as? Int == 2)
    }

    @Test("diagnostics retention preserves newest oversized event instead of emptying log")
    func diagnosticsRetentionPreservesNewestOversizedEventInsteadOfEmptyingLog() throws {
        let directory = try temporaryDirectory().appendingPathComponent("Diagnostics", isDirectory: true)
        let diagnostics = RememBarDiagnostics(
            directory: directory,
            sessionID: "oversized",
            now: IncrementingClock(start: Date(timeIntervalSince1970: 1_800_000_370)).nextDate,
            processID: 447,
            maxLogBytes: 500
        )
        _ = diagnostics.startSession()
        diagnostics.record("large.event", fields: ["payload": String(repeating: "x", count: 2_000)])

        let events = try diagnosticEvents(at: diagnostics.logURL)
        #expect(events.count == 1)
        #expect(events.first?.name == "large.event")
    }

    @Test("crash report scanner parses legacy macOS crash reports")
    func crashReportScannerParsesLegacyMacOSCrashReports() throws {
        let root = try temporaryDirectory()
        let reportURL = root.appendingPathComponent("RememBar-2026-06-27-160500.crash")
        try createTextFile(
            at: reportURL,
            contents: """
            Incident Identifier: 12345678-ABCD
            Process:               RememBar [12345]
            Identifier:            dev.ecn.apps.remembar
            Date/Time:             2026-06-27 16:05:00.000 +0200
            Exception Type:        EXC_BAD_ACCESS (SIGSEGV)
            Exception Codes:       KERN_INVALID_ADDRESS at 0x0000000000000000
            Termination Reason:    Namespace SIGNAL, Code 11 Segmentation fault: 11
            Crashed Thread:        4  Dispatch queue: com.apple.root.utility-qos

            Thread 4 Crashed:
            0   RememBar                       0x0000000100012345 MdfindSpotlightSearch.run(query:root:state:) + 81
            1   RememBar                       0x0000000100012456 closure #1 in MdfindSpotlightSearch.search(query:root:) + 44
            2   libdispatch.dylib              0x0000000181234567 _dispatch_call_block_and_release + 32
            """
        )
        let scanner = RememBarCrashReportScanner(directories: [root])

        let reports = scanner.reports(since: Date(timeIntervalSince1970: 1_700_000_000))

        #expect(reports.count == 1)
        #expect(reports.first?.processName == "RememBar")
        #expect(reports.first?.incidentIdentifier == "12345678-ABCD")
        #expect(reports.first?.exceptionType == "EXC_BAD_ACCESS (SIGSEGV)")
        #expect(reports.first?.terminationReason == "Namespace SIGNAL, Code 11 Segmentation fault: 11")
        #expect(reports.first?.crashedThread == "4  Dispatch queue: com.apple.root.utility-qos")
        #expect(reports.first?.topFrames.contains("MdfindSpotlightSearch.run(query:root:state:)") == true)
    }

    @Test("crash report scanner parses modern macOS ips reports")
    func crashReportScannerParsesModernMacOSIPSReports() throws {
        let root = try temporaryDirectory()
        try createTextFile(
            at: root.appendingPathComponent("RememBar-2026-06-27-160502.ips"),
            contents: """
            {
              "incident": "IPS-1",
              "procName": "RememBar",
              "bundleID": "dev.ecn.apps.remembar",
              "captureTime": "2026-06-27 16:05:02.000 +0200",
              "exception": {
                "type": "EXC_CRASH",
                "signal": "SIGABRT"
              },
              "termination": {
                "namespace": "SIGNAL",
                "code": 6,
                "reason": "Abort trap: 6"
              },
              "threads": [
                {
                  "triggered": false,
                  "frames": [
                    { "symbol": "non-crashing work" }
                  ]
                },
                {
                  "triggered": true,
                  "frames": [
                    { "symbol": "QuickLookFileThumbnail.loadThumbnail()" },
                    { "symbol": "closure #1 in QuickLookFileThumbnail.body.getter" }
                  ]
                }
              ]
            }
            """
        )
        let scanner = RememBarCrashReportScanner(directories: [root])

        let reports = scanner.reports(since: Date(timeIntervalSince1970: 1_700_000_000))

        #expect(reports.count == 1)
        #expect(reports.first?.processName == "RememBar")
        #expect(reports.first?.incidentIdentifier == "IPS-1")
        #expect(reports.first?.identifier == "dev.ecn.apps.remembar")
        #expect(reports.first?.dateTime == "2026-06-27 16:05:02.000 +0200")
        #expect(reports.first?.exceptionType == "EXC_CRASH SIGABRT")
        #expect(reports.first?.terminationReason == "SIGNAL Code 6 Abort trap: 6")
        #expect(reports.first?.crashedThread == "1")
        #expect(reports.first?.topFrames.contains("QuickLookFileThumbnail.loadThumbnail()") == true)
    }

    @Test("crash report scanner parses line delimited modern macOS ips reports")
    func crashReportScannerParsesLineDelimitedModernMacOSIPSReports() throws {
        let root = try temporaryDirectory()
        try createTextFile(
            at: root.appendingPathComponent("RememBar-2026-06-27-160503.ips"),
            contents: """
            {"app_name":"RememBar","timestamp":"2026-06-27 16:05:03.00 +0200","incident_id":"IPS-LINE-1","name":"RememBar"}
            {
              "captureTime" : "2026-06-27 16:05:03.4812 +0200",
              "incident" : "IPS-LINE-1",
              "pid" : 7788,
              "procName" : "RememBar",
              "exception" : {"codes":"0x0, 0x0","type":"EXC_CRASH","signal":"SIGABRT"},
              "termination" : {"code":6,"namespace":"SIGNAL","reason":"Abort trap: 6"},
              "faultingThread" : 0,
              "threads" : [
                {
                  "triggered": true,
                  "id": 141380986,
                  "frames": [
                    {"symbol":"RememBarDiagnostics.appendEventLocked(name:level:fields:file:function:line:)"},
                    {"symbol":"MemorySearchStore.finishSearch()"}
                  ]
                }
              ]
            }
            """
        )
        let scanner = RememBarCrashReportScanner(directories: [root])

        let reports = scanner.reports(since: Date(timeIntervalSince1970: 1_700_000_000), processID: 7788)

        #expect(reports.count == 1)
        #expect(reports.first?.processName == "RememBar")
        #expect(reports.first?.processID == 7788)
        #expect(reports.first?.incidentIdentifier == "IPS-LINE-1")
        #expect(reports.first?.exceptionType == "EXC_CRASH SIGABRT 0x0, 0x0")
        #expect(reports.first?.terminationReason == "SIGNAL Code 6 Abort trap: 6")
        #expect(reports.first?.crashedThread == "141380986")
        #expect(reports.first?.topFrames.contains("RememBarDiagnostics.appendEventLocked") == true)
    }

    @Test("diagnostics correlates previous unclean session with crash report")
    func diagnosticsCorrelatesPreviousUncleanSessionWithCrashReport() throws {
        let root = try temporaryDirectory()
        let diagnosticsDirectory = root.appendingPathComponent("Diagnostics", isDirectory: true)
        let reportsDirectory = root.appendingPathComponent("DiagnosticReports", isDirectory: true)
        let clock = IncrementingClock(start: Date(timeIntervalSince1970: 1_700_000_000))
        let firstRun = RememBarDiagnostics(
            directory: diagnosticsDirectory,
            sessionID: "crashy-run",
            now: clock.nextDate,
            processID: 448,
            maxLogBytes: 200_000
        )
        _ = firstRun.startSession()
        firstRun.record("search.started", fields: ["query": "alpha"])
        try createTextFile(
            at: reportsDirectory.appendingPathComponent("RememBar-2026-06-27-160501.crash"),
            contents: """
            Incident Identifier: CRASH-1
            Process:               RememBar [448]
            Identifier:            dev.ecn.apps.remembar
            Exception Type:        EXC_CRASH (SIGABRT)
            Termination Reason:    Namespace SIGNAL, Code 6 Abort trap: 6
            Crashed Thread:        0

            Thread 0 Crashed:
            0   RememBar                       0x0000000100099999 MemorySearchStore.finishSearch() + 12
            """
        )
        let secondRun = RememBarDiagnostics(
            directory: diagnosticsDirectory,
            sessionID: "next-run",
            now: clock.nextDate,
            processID: 449,
            maxLogBytes: 200_000
        )
        let scanner = RememBarCrashReportScanner(directories: [reportsDirectory])

        _ = secondRun.startSession(crashReportScanner: scanner)

        let events = try diagnosticEvents(at: secondRun.logURL)
        let crash = events.first { $0.name == "diagnostics.crash_report.found" }
        #expect(crash?.fields["previousSessionID"] == "crashy-run")
        #expect(crash?.fields["incidentIdentifier"] == "CRASH-1")
        #expect(crash?.fields["exceptionType"] == "EXC_CRASH (SIGABRT)")
        #expect(crash?.fields["topFrames"]?.contains("MemorySearchStore.finishSearch()") == true)
    }

    @Test("diagnostic event catalog exposes production event names")
    func diagnosticEventCatalogExposesProductionEventNames() {
        #expect(RememBarDiagnosticEvent.searchSubmit == "search.submit")
        #expect(RememBarDiagnosticEvent.mdfindProcessLaunchFailed == "mdfind.process.launch.failed")
        #expect(RememBarDiagnosticEvent.diagnosticsCrashReportFound == "diagnostics.crash_report.found")
        #expect(RememBarDiagnosticEvent.fileSearchAccessDenied == "file_search.access.denied")
        #expect(RememBarDiagnosticEvent.resultOpenSystemSettings == "result.open.system_settings")
        #expect(RememBarDiagnosticEvent.resultOpenExternalApp == "result.open.external_app")
        #expect(RememBarDiagnosticEvent.resultOpenExternalAppRejected == "result.open.external_app.rejected")
        #expect(RememBarDiagnosticEvent.onePasswordProviderFailed == "onepassword.provider.failed")
    }

    @Test("menu bar window placement clamps offscreen panels into the visible frame")
    func menuBarWindowPlacementClampsOffscreenPanelsIntoVisibleFrame() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1728, height: 1079)
        let offscreenPanel = CGRect(x: -409, y: 339, width: 384, height: 441)

        let origin = MenuBarWindowPlacement.adjustedOrigin(
            for: offscreenPanel,
            visibleScreenFrames: [visibleFrame],
            margin: 8
        )

        #expect(origin == CGPoint(x: 8, y: 339))
    }

    @Test("menu bar window placement leaves already visible panels alone")
    func menuBarWindowPlacementLeavesAlreadyVisiblePanelsAlone() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1728, height: 1079)
        let visiblePanel = CGRect(x: 1280, y: 44, width: 384, height: 441)

        let origin = MenuBarWindowPlacement.adjustedOrigin(
            for: visiblePanel,
            visibleScreenFrames: [visibleFrame],
            margin: 8
        )

        #expect(origin == nil)
    }

    @Test("menu bar window placement clamps to the nearest display")
    func menuBarWindowPlacementClampsToNearestDisplay() {
        let laptop = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let external = CGRect(x: 1440, y: 0, width: 1440, height: 900)
        let offRightPanel = CGRect(x: 3200, y: 100, width: 384, height: 441)

        let origin = MenuBarWindowPlacement.adjustedOrigin(
            for: offRightPanel,
            visibleScreenFrames: [laptop, external],
            margin: 8
        )

        #expect(origin == CGPoint(x: 2488, y: 100))
    }

    @Test("menu bar window placement treats compact search panels as candidates")
    func menuBarWindowPlacementTreatsCompactSearchPanelsAsCandidates() {
        #expect(MenuBarWindowPlacement.isPanelCandidate(
            frame: CGRect(x: -4022, y: 39, width: 384, height: 50),
            isVisible: true
        ))
        #expect(!MenuBarWindowPlacement.isPanelCandidate(
            frame: CGRect(x: 0, y: 0, width: 900, height: 50),
            isVisible: true
        ))
        #expect(!MenuBarWindowPlacement.isPanelCandidate(
            frame: CGRect(x: 0, y: 0, width: 384, height: 50),
            isVisible: false
        ))
    }

    @Test("diagnostics detects swift test bundles before enabling shared logger")
    func diagnosticsDetectsSwiftTestBundlesBeforeEnablingSharedLogger() {
        #expect(RememBarDiagnostics.isRunningUnderTests(
            processName: "RememBar",
            environment: [:],
            loadedBundlePaths: ["/tmp/RememBarPackageTests.xctest"],
            arguments: []
        ))
        #expect(RememBarDiagnostics.isRunningUnderTests(
            processName: "RememBarPackageTests",
            environment: [:],
            loadedBundlePaths: [],
            arguments: []
        ))
        #expect(RememBarDiagnostics.isRunningUnderTests(
            processName: "RememBar",
            environment: ["XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration"],
            loadedBundlePaths: [],
            arguments: []
        ))
        #expect(RememBarDiagnostics.isRunningUnderTests(
            processName: "RememBar",
            environment: [:],
            loadedBundlePaths: [],
            arguments: ["/tmp/RememBarPackageTests.xctest/Contents/MacOS/RememBarPackageTests"]
        ))
        #expect(!RememBarDiagnostics.isRunningUnderTests(
            processName: "RememBar",
            environment: [:],
            loadedBundlePaths: ["/Applications/RememBar.app"],
            arguments: ["/Applications/RememBar.app/Contents/MacOS/RememBar"]
        ))
    }

    @Test("diagnostics shared logger is disabled in this test process")
    func diagnosticsSharedLoggerIsDisabledInThisTestProcess() throws {
        let marker = "diagnostics.shared.test_probe.\(UUID().uuidString)"
        let before = (try? String(contentsOf: RememBarDiagnostics.shared.logURL, encoding: .utf8)) ?? ""

        RememBarDiagnostics.shared.record(marker)

        let after = (try? String(contentsOf: RememBarDiagnostics.shared.logURL, encoding: .utf8)) ?? ""
        #expect(!after.contains(marker))
        #expect(after == before)
    }

    @Test("diagnostics default directory honors environment override")
    func diagnosticsDefaultDirectoryHonorsEnvironmentOverride() throws {
        let override = try temporaryDirectory().appendingPathComponent("Smoke Diagnostics", isDirectory: true)

        let directory = RememBarDiagnostics.defaultDirectory(
            environment: ["REMEMBAR_DIAGNOSTICS_DIR": override.path],
            fileManager: .default
        )

        #expect(directory == override)
    }

    @Test("memory search store writes diagnostics for search select open and clear flow")
    func memorySearchStoreWritesDiagnosticsForSearchSelectOpenAndClearFlow() async throws {
        let directory = try temporaryDirectory().appendingPathComponent("Diagnostics", isDirectory: true)
        let diagnostics = RememBarDiagnostics(
            directory: directory,
            sessionID: "store-flow",
            now: IncrementingClock(start: Date(timeIntervalSince1970: 1_800_000_400)).nextDate,
            processID: 555,
            maxLogBytes: 200_000
        )
        _ = diagnostics.startSession()
        let result = MemoryResult(
            id: "history-result",
            title: "Alpha card search",
            detail: "Zen · Jun 27 · example.com",
            refinedDetail: nil,
            url: URL(string: "https://example.com/alpha")!,
            thumbnailURL: nil,
            browser: .zen,
            rank: 12
        )
        let opener = RecordingMemoryResultOpener()
        let store = await MainActor.run {
            MemorySearchStore(
                searchProvider: StaticMemorySearchProvider(results: [result]),
                resultOpener: opener,
                diagnostics: diagnostics
            )
        }

        await MainActor.run {
            store.inputText = "alpha soccer card"
            store.submit()
        }
        _ = await eventually { await MainActor.run { store.results.first?.id == "history-result" } }
        await MainActor.run {
            #expect(store.results.first?.id == "history-result")
            store.select(result)
            store.open(result)
            store.clearSearch()
        }

        let names = try diagnosticEvents(at: diagnostics.logURL).map(\.name)
        #expect(names.contains("search.submit"))
        #expect(names.contains("search.debounce.fired"))
        #expect(names.contains("search.finished"))
        #expect(names.contains("result.select"))
        #expect(names.contains("result.open.requested"))
        #expect(names.contains("search.clear"))
    }

    @Test("search flow redacts secret file paths and suppresses preview end-to-end")
    func searchFlowRedactsSecretPathsEndToEnd() async throws {
        // The production wire the menu-bar UI drives: inputText -> submit -> real
        // MemorySearchStore -> real RememBarDiagnostics. Proves the secret-leak fix
        // holds on the real path, not just in isolation.
        let directory = try temporaryDirectory().appendingPathComponent("Diagnostics", isDirectory: true)
        let diagnostics = RememBarDiagnostics(
            directory: directory,
            sessionID: "secret-flow",
            now: IncrementingClock(start: Date(timeIntervalSince1970: 1_800_000_900)).nextDate,
            processID: 778,
            maxLogBytes: 200_000
        )
        _ = diagnostics.startSession()

        let secretFile = MemoryResult(
            fileURL: URL(fileURLWithPath: "/Users/x/Downloads/github-recovery-codes.txt"),
            displayPath: "Downloads/github-recovery-codes.txt",
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_000),
            rank: 100
        )
        let store = await MainActor.run {
            MemorySearchStore(
                searchProvider: StaticMemorySearchProvider(results: [secretFile]),
                resultOpener: RecordingMemoryResultOpener(),
                diagnostics: diagnostics
            )
        }
        await MainActor.run {
            store.inputText = "recovery codes"
            store.submit()
        }
        _ = await eventually { await MainActor.run { !store.results.isEmpty } }

        await MainActor.run {
            // Vector B: the surfaced result carries no Quick Look content preview.
            #expect(store.results.first?.thumbnail == nil)
        }

        // Vector A: not one written diagnostic field anywhere contains the raw secret leaf.
        let events = try diagnosticEvents(at: diagnostics.logURL)
        #expect(!events.isEmpty)
        for event in events {
            for (key, value) in event.fields {
                #expect(value.contains("github-recovery-codes.txt") == false,
                        "raw secret path leaked in \(event.name).\(key)")
            }
        }
    }

    @MainActor
    @Test("grant-access remediation opens Full Disk Access settings via the opener")
    func grantAccessRemediationOpensSettings() {
        let opener = RecordingMemoryResultOpener()
        let store = MemorySearchStore(searchProvider: StaticMemorySearchProvider(results: []), resultOpener: opener)
        store.performRemediation(.grantFullDiskAccess)
        #expect(opener.opened.count == 1)
        if case .systemSettings(let url)? = opener.opened.first?.target {
            #expect(url == FileSearchAccessIssue.fullDiskAccessSettingsURL)
        } else {
            Issue.record("expected a .systemSettings open for grant-access")
        }
    }

    @Test("browser identities preserve source app handoff data")
    func browserIdentity() {
        #expect(BrowserRef.chrome.bundleIdentifier == "com.google.Chrome")
        #expect(BrowserRef.safari.bundleIdentifier == "com.apple.Safari")
        #expect(BrowserRef.zen.bundleIdentifier == "app.zen-browser.zen")
        #expect(BrowserRef.zen.bundlePathHint == "/Applications/Zen.app")
    }

    @Test("workspace opener resolves Zen without default-browser fallback")
    func workspaceOpenerResolvesZen() {
        let appURL = WorkspaceBrowserOpener.applicationURL(for: .zen)

        #expect(appURL?.lastPathComponent == "Zen.app")
    }

    @Test("workspace opener fails closed for unresolved browsers")
    func workspaceOpenerFailsClosedForUnresolvedBrowsers() {
        let missing = BrowserRef(
            displayName: "Missing",
            bundleIdentifier: "com.example.DoesNotExist",
            bundlePathHint: "/Applications/Definitely Missing Browser.app"
        )

        #expect(WorkspaceBrowserOpener.applicationURL(for: missing) == nil)
    }

    @Test("workspace opener only allows web URLs")
    func workspaceOpenerAllowsOnlyWebURLs() {
        #expect(WorkspaceBrowserOpener.canOpen(URL(string: "https://example.com")!))
        #expect(WorkspaceBrowserOpener.canOpen(URL(string: "http://example.com")!))
        #expect(!WorkspaceBrowserOpener.canOpen(URL(string: "file:///tmp/example")!))
        #expect(!WorkspaceBrowserOpener.canOpen(URL(string: "data:text/plain,hello")!))
        #expect(!WorkspaceBrowserOpener.canOpen(URL(string: "x-custom://open")!))
    }

    @Test("RememBar menu glyph resource loads")
    func rememBarMenuGlyphResourceLoads() {
        #expect(RememBarImage.nsMenuGlyph != nil)
    }

    @Test("RememBar menu glyph uses menu bar dimensions")
    func rememBarMenuGlyphUsesMenuBarDimensions() throws {
        let glyph = try #require(RememBarImage.nsMenuGlyph)

        #expect(glyph.size.width <= 22)
        #expect(glyph.size.height <= 22)
    }

    @Test("history result kind classifies youtube containers and videos")
    func historyResultKindClassifiesYouTubeContainersAndVideos() {
        #expect(HistoryResultKind(url: URL(string: "https://www.youtube.com/watch?v=abc123")!) == .youtubeVideo(id: "abc123"))
        #expect(HistoryResultKind(url: URL(string: "https://www.youtube.com/shorts/Q6XsRp31zwk")!) == .youtubeShort(id: "Q6XsRp31zwk"))
        #expect(HistoryResultKind(url: URL(string: "https://www.youtube.com/results?search_query=cold+ones+compilation")!) == .youtubeSearch(query: "cold ones compilation"))
        #expect(HistoryResultKind(url: URL(string: "https://www.youtube.com/@coldones/videos")!) == .youtubeChannel(label: "@coldones"))
        #expect(HistoryResultKind(url: URL(string: "https://www.youtube.com/playlist?list=PL123")!) == .youtubePlaylist)
        #expect(HistoryResultKind(url: URL(string: "https://notyoutube.com/watch?v=abc123")!) == .web)
    }

    @Test("youtube container results use custom tiles instead of favicon thumbnails")
    func youtubeContainerResultsUseCustomTilesInsteadOfFavicons() {
        for url in [
            URL(string: "https://www.youtube.com/results?search_query=cold+ones+compilation")!,
            URL(string: "https://www.youtube.com/@coldones/videos")!,
            URL(string: "https://www.youtube.com/playlist?list=PL123")!
        ] {
            let result = MemoryResult(historyItem: HistoryItem(
                browser: .zen,
                profile: "Default",
                visitedAt: Date(timeIntervalSince1970: 1_800_000_000),
                title: "YouTube container",
                url: url,
                sourcePath: "/tmp/zen"
            ))

            #expect(result.thumbnailURL == nil)
        }
    }

    @Test("history source discovery classifies chromium firefox and safari")
    func historySourceDiscoveryClassifiesFamilies() throws {
        let root = try temporaryDirectory()
        try createEmptyFile(at: root.appendingPathComponent("Library/Safari/History.db"))
        try createEmptyFile(at: root.appendingPathComponent("Library/Application Support/Google/Chrome/Default/History"))
        try createEmptyFile(at: root.appendingPathComponent("Library/Application Support/zen/Profiles/abc.default/places.sqlite"))

        let sources = HistorySource.discover(home: root)

        #expect(sources.contains { $0.family == .safari && $0.browser.displayName == "Safari" })
        #expect(sources.contains { $0.family == .chromium && $0.browser.displayName == "Chrome" })
        #expect(sources.contains { $0.family == .firefox && $0.browser.displayName == "Zen" })
    }

    @Test("history source discovery includes non-default chromium profiles")
    func historySourceDiscoveryIncludesChromiumProfiles() throws {
        let root = try temporaryDirectory()
        try createEmptyFile(at: root.appendingPathComponent("Library/Application Support/Google/Chrome/Profile 1/History"))
        try createEmptyFile(at: root.appendingPathComponent("Library/Application Support/com.operasoftware.Opera/History"))

        let sources = HistorySource.discover(home: root)

        #expect(sources.contains { $0.family == .chromium && $0.browser == .chrome && $0.profile == "Profile 1" })
        #expect(sources.contains { $0.family == .chromium && $0.browser == .opera && $0.profile == "com.operasoftware.Opera" })
    }

    @Test("history source discovery reports profile root enumeration failures")
    func historySourceDiscoveryReportsProfileRootEnumerationFailures() throws {
        let root = try temporaryDirectory()
        try createEmptyFile(at: root.appendingPathComponent("Library/Application Support/Google/Chrome/Default/History"))
        try createTextFile(
            at: root.appendingPathComponent("Library/Application Support/Firefox/Profiles"),
            contents: "not a directory"
        )

        let report = HistorySource.discoverReport(home: root)

        #expect(report.sources.contains { $0.browser == .chrome })
        #expect(report.issues.contains { issue in
            issue.root.path.hasSuffix("Library/Application Support/Firefox/Profiles") &&
                issue.errorDescription.isEmpty == false
        })
    }

    @Test("history source discovery reports chromium root enumeration failures")
    func historySourceDiscoveryReportsChromiumRootEnumerationFailures() throws {
        let root = try temporaryDirectory()
        try createTextFile(
            at: root.appendingPathComponent("Library/Application Support/Google/Chrome"),
            contents: "not a directory"
        )

        let report = HistorySource.discoverReport(home: root)

        #expect(report.sources.isEmpty)
        #expect(report.issues.contains { issue in
            issue.root.path.hasSuffix("Library/Application Support/Google/Chrome") &&
                issue.errorDescription.isEmpty == false
        })
    }

    @Test("history source discovery ignores missing browser roots")
    func historySourceDiscoveryIgnoresMissingBrowserRoots() throws {
        let root = try temporaryDirectory()

        let report = HistorySource.discoverReport(home: root)

        #expect(report.sources.isEmpty)
        #expect(report.issues.isEmpty)
    }

    @Test("browser family mapping preserves non-default app identities")
    func browserFamilyMappingPreservesAppIdentity() {
        #expect(BrowserRef.chromiumFamily(forPath: "/users/me/library/application support/google/chrome for testing/default/history") == .chromeForTesting)
        #expect(BrowserRef.chromiumFamily(forPath: "/users/me/library/application support/arc/user data/profile 1/history") == .arc)
        #expect(BrowserRef.chromiumFamily(forPath: "/users/me/library/application support/bravesoftware/brave-browser/default/history") == .brave)
        #expect(BrowserRef.chromiumFamily(forPath: "/users/me/library/application support/microsoft edge/profile 2/history") == .edge)
        #expect(BrowserRef.chromiumFamily(forPath: "/users/me/library/application support/vivaldi/default/history") == .vivaldi)
        #expect(BrowserRef.chromiumFamily(forPath: "/users/me/library/application support/com.operasoftware.opera/history") == .opera)
        #expect(BrowserRef.chromiumFamily(forPath: "/users/me/library/application support/chromium/default/history") == .chromium)
        #expect(BrowserRef.firefoxFamily(forPath: "/users/me/library/application support/firefox/profiles/main/places.sqlite") == .firefox)
        #expect(BrowserRef.firefoxFamily(forPath: "/users/me/library/application support/zen/profiles/main/places.sqlite") == .zen)
        #expect(BrowserRef.firefoxFamily(forPath: "/users/me/library/application support/waterfox/profiles/main/places.sqlite") == .waterfox)
        #expect(BrowserRef.firefoxFamily(forPath: "/users/me/library/application support/librewolf/profiles/main/places.sqlite") == .libreWolf)
    }

    @Test("history search window defaults to thirty one days")
    func historySearchWindowDefaultsToThirtyOneDays() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let since = HistorySearchWindow.default.since(now: now)

        #expect(since == now.addingTimeInterval(-TimeInterval(31 * 24 * 60 * 60)))
    }

    @Test("local history provider resolves recent window at read time")
    func localHistoryProviderResolvesRecentWindowAtReadTime() throws {
        let root = try temporaryDirectory()
        try createChromiumHistory(
            at: root.appendingPathComponent("Library/Application Support/Google/Chrome/Default/History"),
            title: "Moving Window Row",
            url: "https://example.com/moving-window-row",
            visitTime: 13_426_152_000_000_000
        )
        let provider = LocalHistorySearchProvider(home: root, window: .recent(days: 31))
        let rowDate = HistoryDate.chromium(13_426_152_000_000_000)

        let included = provider.readReport(now: rowDate.addingTimeInterval(TimeInterval(30 * 24 * 60 * 60)))
        let excluded = provider.readReport(now: rowDate.addingTimeInterval(TimeInterval(32 * 24 * 60 * 60)))

        #expect(included.rows.map(\.title) == ["Moving Window Row"])
        #expect(excluded.rows.isEmpty)
    }

    @Test("local history provider searches chromium fixture")
    func localHistoryProviderSearchesChromiumFixture() async throws {
        let root = try temporaryDirectory()
        let db = root.appendingPathComponent("Library/Application Support/Google/Chrome/Default/History")
        try createChromiumHistory(
            at: db,
            title: "D'Leesa - Healer Official Video",
            url: "https://www.youtube.com/watch?v=healer123",
            visitTime: 13_426_152_000_000_000
        )

        let provider = LocalHistorySearchProvider(home: root, since: nil)
        let results = await provider.search(query: "dleesa healer youtube", refinements: [], limit: 5)

        #expect(results.first?.title == "D'Leesa - Healer Official Video")
        #expect(results.first?.browser == .chrome)
        #expect(results.first?.thumbnailURL?.absoluteString == "https://img.youtube.com/vi/healer123/hqdefault.jpg")
    }

    @Test("local history provider derives favicon thumbnails for web pages")
    func localHistoryProviderDerivesFaviconThumbnailsForWebPages() async throws {
        let root = try temporaryDirectory()
        try createChromiumHistory(
            at: root.appendingPathComponent("Library/Application Support/Google/Chrome/Default/History"),
            title: "Cloudflare Audit Logs",
            url: "https://dash.cloudflare.com/audit-logs",
            visitTime: 13_426_152_000_000_000
        )

        let results = await LocalHistorySearchProvider(home: root, since: nil).search(
            query: "cloudflare audit",
            refinements: [],
            limit: 5
        )

        #expect(results.first?.thumbnailURL?.absoluteString == "https://www.google.com/s2/favicons?domain=dash.cloudflare.com&sz=128")
    }

    @Test("local history provider keeps localhost thumbnails local")
    func localHistoryProviderKeepsLocalhostThumbnailsLocal() async throws {
        let root = try temporaryDirectory()
        try createChromiumHistory(
            at: root.appendingPathComponent("Library/Application Support/Google/Chrome/Default/History"),
            title: "Localhost App",
            url: "http://localhost:3000/dashboard",
            visitTime: 13_426_152_000_000_000
        )

        let results = await LocalHistorySearchProvider(home: root, since: nil).search(
            query: "localhost app",
            refinements: [],
            limit: 5
        )

        #expect(results.first?.thumbnailURL == nil)
    }

    @Test("local history provider keeps base matches when refinements are extra context")
    func localHistoryProviderKeepsBaseMatchesWithRefinements() async throws {
        let root = try temporaryDirectory()
        let db = root.appendingPathComponent("Library/Application Support/Google/Chrome/Default/History")
        try createChromiumHistory(
            at: db,
            title: "Sample Workflow Video",
            url: "https://www.youtube.com/watch?v=sample00001",
            visitTime: 13_426_152_000_000_000
        )

        let provider = LocalHistorySearchProvider(home: root, since: nil)
        let results = await provider.search(query: "workflow", refinements: ["ship studio"], limit: 5)

        #expect(results.first?.url.absoluteString == "https://www.youtube.com/watch?v=sample00001")
    }

    @Test("history ranker treats youtube as domain intent not enough content evidence")
    func historyRankerTreatsYouTubeAsDomainIntent() {
        let recent = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = [
            HistoryItem(
                browser: .zen,
                profile: "Default",
                visitedAt: recent,
                title: "Cold Ones Arab Mug Compilation - YouTube",
                url: URL(string: "https://www.youtube.com/watch?v=coldones")!,
                sourcePath: "/tmp/zen"
            ),
            HistoryItem(
                browser: .zen,
                profile: "Default",
                visitedAt: recent.addingTimeInterval(10),
                title: "Audit logs",
                url: URL(string: "https://dash.cloudflare.com/audit-logs")!,
                sourcePath: "/tmp/zen"
            ),
            HistoryItem(
                browser: .zen,
                profile: "Default",
                visitedAt: recent.addingTimeInterval(20),
                title: "Unrelated YouTube Video",
                url: URL(string: "https://www.youtube.com/watch?v=unrelated")!,
                sourcePath: "/tmp/zen"
            )
        ]

        let results = HistoryRanker.search(rows: rows, query: "youtube cold ones", limit: 5)

        #expect(results.map(\.title) == ["Cold Ones Arab Mug Compilation - YouTube"])
    }

    @Test("history ranker prioritizes youtube watch pages over search pages")
    func historyRankerPrioritizesYouTubeWatchPagesOverSearchPages() {
        let recent = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = [
            HistoryItem(
                browser: .zen,
                profile: "Default",
                visitedAt: recent.addingTimeInterval(10),
                title: "cold ones compilation - YouTube",
                url: URL(string: "https://www.youtube.com/results?search_query=cold+ones+compilation")!,
                sourcePath: "/tmp/zen"
            ),
            HistoryItem(
                browser: .zen,
                profile: "Default",
                visitedAt: recent,
                title: "Cold Ones Arab Mug Compilation - YouTube",
                url: URL(string: "https://www.youtube.com/watch?v=coldones")!,
                sourcePath: "/tmp/zen"
            )
        ]

        let results = HistoryRanker.search(rows: rows, query: "youtube cold ones", limit: 2)

        #expect(results.map(\.title).first == "Cold Ones Arab Mug Compilation - YouTube")
    }

    @Test("history ranker applies youtube intent from refinements")
    func historyRankerAppliesYouTubeIntentFromRefinements() {
        let recent = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = [
            HistoryItem(
                browser: .zen,
                profile: "Default",
                visitedAt: recent,
                title: "Cold Ones Arab Mug Compilation - YouTube",
                url: URL(string: "https://www.youtube.com/watch?v=coldones")!,
                sourcePath: "/tmp/zen"
            ),
            HistoryItem(
                browser: .zen,
                profile: "Default",
                visitedAt: recent.addingTimeInterval(10),
                title: "Cold Ones article",
                url: URL(string: "https://example.com/cold-ones")!,
                sourcePath: "/tmp/zen"
            )
        ]

        let results = HistoryRanker.search(rows: rows, query: "cold ones", refinements: ["youtube"], limit: 5)

        #expect(results.map(\.title) == ["Cold Ones Arab Mug Compilation - YouTube"])
    }

    @Test("history ranker boosts videos for domain only youtube searches")
    func historyRankerBoostsVideosForDomainOnlyYouTubeSearches() {
        let recent = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = [
            HistoryItem(
                browser: .zen,
                profile: "Default",
                visitedAt: recent.addingTimeInterval(20),
                title: "YouTube",
                url: URL(string: "https://www.youtube.com/")!,
                sourcePath: "/tmp/zen"
            ),
            HistoryItem(
                browser: .zen,
                profile: "Default",
                visitedAt: recent,
                title: "Actual video - YouTube",
                url: URL(string: "https://www.youtube.com/watch?v=actual")!,
                sourcePath: "/tmp/zen"
            )
        ]

        let results = HistoryRanker.search(rows: rows, query: "youtube", limit: 2)

        #expect(results.map(\.title).first == "Actual video - YouTube")
    }

    @Test("history ranker does not treat fake youtube suffix hosts as youtube")
    func historyRankerDoesNotTreatFakeYouTubeSuffixHostsAsYouTube() {
        let recent = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = [
            HistoryItem(
                browser: .zen,
                profile: "Default",
                visitedAt: recent,
                title: "Cold Ones fake host",
                url: URL(string: "https://notyoutube.com/cold-ones")!,
                sourcePath: "/tmp/zen"
            ),
            HistoryItem(
                browser: .zen,
                profile: "Default",
                visitedAt: recent.addingTimeInterval(10),
                title: "Cold Ones real host",
                url: URL(string: "https://www.youtube.com/watch?v=coldones")!,
                sourcePath: "/tmp/zen"
            )
        ]

        let results = HistoryRanker.search(rows: rows, query: "youtube cold ones", limit: 5)

        #expect(results.map(\.title) == ["Cold Ones real host"])
    }

    @Test("history ranker prefers complete multi term matches")
    func historyRankerPrefersCompleteMultiTermMatches() {
        let recent = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = [
            HistoryItem(
                browser: .zen,
                profile: "Default",
                visitedAt: recent,
                title: "Cold Ones Arab Mug Compilation - YouTube",
                url: URL(string: "https://www.youtube.com/watch?v=coldones")!,
                sourcePath: "/tmp/zen"
            ),
            HistoryItem(
                browser: .zen,
                profile: "Default",
                visitedAt: recent.addingTimeInterval(10),
                title: "One unrelated page",
                url: URL(string: "https://example.com/one-unrelated-page")!,
                sourcePath: "/tmp/zen"
            ),
            HistoryItem(
                browser: .zen,
                profile: "Default",
                visitedAt: recent.addingTimeInterval(20),
                title: "Audit logs",
                url: URL(string: "https://dash.cloudflare.com/audit-log?resource_scope=accounts,zones")!,
                sourcePath: "/tmp/zen"
            )
        ]

        let results = HistoryRanker.search(rows: rows, query: "cold ones", limit: 5)

        #expect(results.map(\.title) == ["Cold Ones Arab Mug Compilation - YouTube"])
    }

    @Test("local history provider derives youtube shorts thumbnails")
    func localHistoryProviderDerivesYouTubeShortsThumbnails() async throws {
        let root = try temporaryDirectory()
        try createChromiumHistory(
            at: root.appendingPathComponent("Library/Application Support/Google/Chrome/Default/History"),
            title: "TiaCorine Has A Hit With This One! - YouTube",
            url: "https://www.youtube.com/shorts/Q6XsRp31zwk",
            visitTime: 13_426_152_000_000_000
        )

        let results = await LocalHistorySearchProvider(home: root, since: nil).search(
            query: "youtube tiacorine",
            refinements: [],
            limit: 5
        )

        #expect(results.first?.thumbnailURL?.absoluteString == "https://img.youtube.com/vi/Q6XsRp31zwk/hqdefault.jpg")
    }

    @Test("local history provider filters rows before the search window")
    func localHistoryProviderFiltersRowsBeforeSearchWindow() async throws {
        let root = try temporaryDirectory()
        let db = root.appendingPathComponent("Library/Application Support/Google/Chrome/Default/History")
        try createChromiumHistory(
            at: db,
            rows: [
                ChromiumHistoryFixture(
                    title: "Window Match Recent",
                    url: "https://example.com/window-recent",
                    visitTime: 13_426_152_000_000_000
                ),
                ChromiumHistoryFixture(
                    title: "Window Match Old",
                    url: "https://example.com/window-old",
                    visitTime: 13_390_531_200_000_000
                )
            ]
        )

        let provider = LocalHistorySearchProvider(
            home: root,
            since: Date(timeIntervalSince1970: 1_750_000_000)
        )
        let results = await provider.search(query: "window match", refinements: [], limit: 5)

        #expect(results.map(\.title) == ["Window Match Recent"])
    }

    @Test("local history provider supports unbounded search window")
    func localHistoryProviderSupportsUnboundedSearchWindow() async throws {
        let root = try temporaryDirectory()
        let db = root.appendingPathComponent("Library/Application Support/Google/Chrome/Default/History")
        try createChromiumHistory(
            at: db,
            title: "Old Unbounded Match",
            url: "https://example.com/old-unbounded-match",
            visitTime: 13_390_531_200_000_000
        )

        let results = await LocalHistorySearchProvider(home: root, since: nil).search(
            query: "old unbounded",
            refinements: [],
            limit: 5
        )

        #expect(results.map(\.title) == ["Old Unbounded Match"])
    }

    @Test("local history provider searches beyond five thousand recent firefox visits")
    func localHistoryProviderSearchesBeyondFiveThousandRecentFirefoxVisits() async throws {
        let root = try temporaryDirectory()
        let profile = root.appendingPathComponent("Library/Application Support/zen/Profiles/main.default")
        let db = profile.appendingPathComponent("places.sqlite")
        let targetVisit = Int64(1_800_000_000_000_000)
        let newerRows = (1...5_001).map { index in
            FirefoxHistoryFixture(
                title: "Newer unrelated \(index)",
                url: "https://example.com/newer-\(index)",
                visitDate: targetVisit + Int64(index * 1_000_000)
            )
        }
        try createFirefoxHistory(
            at: db,
            rows: newerRows + [
                FirefoxHistoryFixture(
                    title: "COLD ONES Arab Mug Compilation - YouTube",
                    url: "https://www.youtube.com/watch?v=I0P1dyW0Jps",
                    visitDate: targetVisit
                )
            ]
        )

        let results = await LocalHistorySearchProvider(
            home: root,
            since: Date(timeIntervalSince1970: 1_799_990_000)
        ).search(query: "cold ones", refinements: [], limit: 5)

        #expect(results.map(\.title) == ["COLD ONES Arab Mug Compilation - YouTube"])
    }

    @Test("local history provider filters safari fractional visit times after conversion")
    func localHistoryProviderFiltersSafariFractionalVisitTimes() async throws {
        let root = try temporaryDirectory()
        try createSafariHistory(
            at: root.appendingPathComponent("Library/Safari/History.db"),
            title: "Safari Fractional Boundary",
            url: "https://example.com/safari-fractional-boundary",
            visitTime: 1_000.6
        )

        let results = await LocalHistorySearchProvider(
            home: root,
            since: Date(timeInterval: 1_000.4, since: Date(timeIntervalSinceReferenceDate: 0))
        ).search(query: "safari fractional", refinements: [], limit: 5)

        #expect(results.map(\.title) == ["Safari Fractional Boundary"])
    }

    @Test("local history read report keeps rows and source failures separate")
    func localHistoryReadReportSeparatesRowsFromSourceFailures() throws {
        let root = try temporaryDirectory()
        try createChromiumHistory(
            at: root.appendingPathComponent("Library/Application Support/Google/Chrome/Default/History"),
            title: "Working History Row",
            url: "https://example.com/working-history-row",
            visitTime: 13_426_152_000_000_000
        )
        try createTextFile(
            at: root.appendingPathComponent("Library/Application Support/com.operasoftware.Opera/History"),
            contents: "not a sqlite database"
        )

        let report = LocalHistorySearchProvider(home: root, since: nil).readReport()

        #expect(report.rows.map(\.title).contains("Working History Row"))
        #expect(report.sourceReads.contains { $0.source.browser == .chrome && $0.errorDescription == nil })
        #expect(report.sourceReads.contains { read in
            read.source.browser == .opera &&
                read.rows.isEmpty &&
                read.errorDescription?.isEmpty == false
        })
    }

    @Test("local history read report carries discovery failures")
    func localHistoryReadReportCarriesDiscoveryFailures() throws {
        let root = try temporaryDirectory()
        try createTextFile(
            at: root.appendingPathComponent("Library/Application Support/Firefox/Profiles"),
            contents: "not a directory"
        )

        let report = LocalHistorySearchProvider(home: root, since: nil).readReport()

        #expect(report.discoveryIssues.contains { issue in
            issue.root.path.hasSuffix("Library/Application Support/Firefox/Profiles") &&
                issue.errorDescription.isEmpty == false
        })
    }

    @Test("local history search keeps good results when another source fails")
    func localHistorySearchKeepsGoodResultsWhenAnotherSourceFails() async throws {
        let root = try temporaryDirectory()
        try createChromiumHistory(
            at: root.appendingPathComponent("Library/Application Support/Google/Chrome/Default/History"),
            title: "Survives Broken Source",
            url: "https://example.com/survives-broken-source",
            visitTime: 13_426_152_000_000_000
        )
        try createTextFile(
            at: root.appendingPathComponent("Library/Application Support/com.operasoftware.Opera/History"),
            contents: "not a sqlite database"
        )

        let results = await LocalHistorySearchProvider(home: root, since: nil).search(
            query: "survives broken source",
            refinements: [],
            limit: 5
        )

        #expect(results.map(\.title).contains("Survives Broken Source"))
    }

    @Test("history provider reports blocked source reads")
    func historyProviderReportsBlockedSourceReads() async throws {
        let root = try temporaryDirectory()
        let safari = root.appendingPathComponent("Library/Safari", isDirectory: true)
        try FileManager.default.createDirectory(at: safari, withIntermediateDirectories: true)
        let db = safari.appendingPathComponent("History.db")
        FileManager.default.createFile(atPath: db.path, contents: Data("not sqlite".utf8))

        let provider = LocalHistorySearchProvider(home: root, since: nil)
        let response = await provider.searchResponse(query: "facebook recovery", refinements: [], limit: 5)

        #expect(response.sourceStatuses.contains {
            $0.sourceName.contains("Safari") && ($0.state == .failed || $0.state == .blocked)
        })
    }

    @Test("history provider reports unavailable when no history sources are discovered")
    func historyProviderReportsUnavailableWhenNoSourcesAreDiscovered() async throws {
        let root = try temporaryDirectory()
        let provider = LocalHistorySearchProvider(home: root, since: nil)

        let response = await provider.searchResponse(query: "facebook recovery", refinements: [], limit: 5)

        #expect(response.sourceStatuses == [
            MemorySearchSourceStatus(
                id: "history",
                sourceName: "Browser History",
                state: .unavailable,
                detail: "No browser history databases found"
            )
        ])
    }

    @Test("spotlight query plan maps photoshop intent and escapes literals")
    func spotlightQueryPlanMapsPhotoshopIntentAndEscapesLiterals() {
        let plan = SpotlightFileQueryPlan(query: #"alpha "card" photoshop file"#, refinements: [#"back\slash"#])

        #expect(plan.searchTerms == ["alpha", "card", "back", "slash"])
        #expect(plan.entityTerms == ["alpha", "back", "slash"])
        #expect(plan.descriptorTerms == ["card"])
        #expect(plan.query.contains(#"kMDItemFSName == "*.psd"cd"#))
        #expect(plan.query.contains(#"kMDItemFSName == "*.psb"cd"#))
        #expect(plan.query.contains(#"kMDItemFSName == "*.psdt"cd"#))
        #expect(SpotlightFileQueryPlan.escapeLiteral(#"quote"and\slash"#) == #"quote\"and\\slash"#)
    }

    @Test("spotlight query plan keeps explicit photoshop extensions specific")
    func spotlightQueryPlanKeepsExplicitPhotoshopExtensionsSpecific() {
        let psbPlan = SpotlightFileQueryPlan(query: "alpha psb", refinements: [])
        let photoshopPlan = SpotlightFileQueryPlan(query: "alpha photoshop", refinements: [])

        #expect(psbPlan.allowedExtensions == ["psb"])
        #expect(psbPlan.query.contains(#"kMDItemFSName == "*.psb"cd"#))
        #expect(!psbPlan.query.contains(#"kMDItemFSName == "*.psd"cd"#))
        #expect(photoshopPlan.allowedExtensions == ["psd", "psb", "psdt"])
    }

    @Test("spotlight query plan treats explicit image extensions as constraints")
    func spotlightQueryPlanTreatsExplicitImageExtensionsAsConstraints() {
        for fileExtension in ["png", "jpg", "jpeg", "heic", "gif", "webp", "tif", "tiff"] {
            let directPlan = SpotlightFileQueryPlan(query: "alpha \(fileExtension)", refinements: [])
            let refinementPlan = SpotlightFileQueryPlan(query: "alpha", refinements: [fileExtension])

            #expect(directPlan.searchTerms == ["alpha"])
            #expect(directPlan.allowedExtensions == [fileExtension])
            #expect(directPlan.query.contains(#"kMDItemFSName == "*.\#(fileExtension)"cd"#))
            #expect(!directPlan.query.contains(#""*\#(fileExtension)*""#))
            #expect(refinementPlan == directPlan)
        }
    }

    @Test("spotlight query plan treats sports and template words as descriptors")
    func spotlightQueryPlanTreatsSportsAndTemplateWordsAsDescriptors() {
        let plan = SpotlightFileQueryPlan(query: "alpha soccer card photoshop", refinements: [])

        #expect(plan.entityTerms == ["alpha"])
        #expect(plan.descriptorTerms == ["soccer", "card"])
    }

    @Test("spotlight query plan keeps ramble context out of identity terms")
    func spotlightQueryPlanKeepsRambleContextOutOfIdentityTerms() {
        let plan = SpotlightFileQueryPlan(query: "alpha soccer card keep total gold numbers 85 png", refinements: [])

        #expect(plan.entityTerms == ["alpha"])
        #expect(plan.descriptorTerms == ["soccer", "card", "keep", "total", "gold", "numbers", "85"])
        #expect(plan.allowedExtensions == ["png"])
        #expect(plan.query.contains(#""*alpha*""#))
        #expect(!plan.query.contains(#""*keep*""#))
        #expect(!plan.query.contains(#""*total*""#))
        #expect(!plan.query.contains(#""*gold*""#))
        #expect(!plan.query.contains(#""*numbers*""#))
        #expect(!plan.query.contains(#""*85*""#))
        #expect(plan.hasExplicitFileIntent)
    }

    @Test("spotlight file provider ranks exact photoshop files and collapses duplicate filenames")
    func spotlightFileProviderRanksExactPhotoshopFilesAndCollapsesDuplicateFilenames() async throws {
        let root = try temporaryDirectory()
        let mainAlpha = root.appendingPathComponent("Documents/Total/alpha.psd")
        let copiedAlpha = root.appendingPathComponent("Documents/Total/Total 2/alpha.psd")
        let alphaImage = root.appendingPathComponent("Documents/Total/AlphaImage.psd")
        let casey = root.appendingPathComponent("Documents/Total/Keep/casey.psd")
        try createEmptyFile(at: copiedAlpha)
        try createEmptyFile(at: alphaImage)
        try createEmptyFile(at: casey)
        try createEmptyFile(at: mainAlpha)

        let provider = SpotlightFileSearchProvider(
            home: root,
            spotlight: StubSpotlightSearch(
                urls: [copiedAlpha, alphaImage, casey, mainAlpha]
            )
        )

        let results = await provider.search(
            query: "photoshop card for alpha and casey",
            refinements: [],
            limit: 5
        )

        #expect(results.first?.url == mainAlpha)
        #expect(results.map(\.title).contains("casey.psd"))
        #expect(results.filter { $0.title.lowercased() == "alpha.psd" }.count == 1)
        #expect(results.first?.target == .file(mainAlpha))
        #expect(results.first?.copyValue == mainAlpha.path)
        #expect(results.first?.detail.contains("File ·") == true)
        #expect(results.first?.thumbnailURL == nil)
        #expect(results.first?.thumbnail == .filePreview(mainAlpha))
    }

    @Test("spotlight file provider writes diagnostics for failed backend searches")
    func spotlightFileProviderWritesDiagnosticsForFailedBackendSearches() async throws {
        let root = try temporaryDirectory()
        let diagnostics = RememBarDiagnostics(
            directory: root.appendingPathComponent("Diagnostics", isDirectory: true),
            sessionID: "spotlight-provider",
            now: IncrementingClock(start: Date(timeIntervalSince1970: 1_800_000_500)).nextDate,
            processID: 666,
            maxLogBytes: 200_000
        )
        _ = diagnostics.startSession()
        let provider = SpotlightFileSearchProvider(
            home: root,
            spotlight: ThrowingSpotlightSearch(),
            diagnostics: diagnostics
        )

        let results = await provider.search(query: "photoshop card alpha", refinements: [], limit: 5)

        #expect(results.isEmpty)
        let events = try diagnosticEvents(at: diagnostics.logURL)
        #expect(events.contains { $0.name == "spotlight.provider.started" && $0.fields["query"]?.contains("alpha") == true })
        #expect(events.contains { $0.name == "spotlight.provider.failed" && $0.fields["error"]?.contains("forced spotlight failure") == true })
    }

    @Test("local history provider writes diagnostics for empty source searches")
    func localHistoryProviderWritesDiagnosticsForEmptySourceSearches() async throws {
        let root = try temporaryDirectory()
        let diagnostics = RememBarDiagnostics(
            directory: root.appendingPathComponent("Diagnostics", isDirectory: true),
            sessionID: "history-provider",
            now: IncrementingClock(start: Date(timeIntervalSince1970: 1_800_000_600)).nextDate,
            processID: 777,
            maxLogBytes: 200_000
        )
        _ = diagnostics.startSession()
        let provider = LocalHistorySearchProvider(
            home: root,
            window: .unbounded,
            diagnostics: diagnostics
        )

        let results = await provider.search(query: "alpha soccer card", refinements: [], limit: 5)

        #expect(results.isEmpty)
        let events = try diagnosticEvents(at: diagnostics.logURL)
        #expect(events.contains { $0.name == "history.provider.started" && $0.fields["query"] == "alpha soccer card" })
        #expect(events.contains { $0.name == "history.discovery.finished" && $0.fields["sourceCount"] == "0" })
        #expect(events.contains { $0.name == "history.provider.finished" && $0.fields["rowCount"] == "0" && $0.fields["resultCount"] == "0" })
    }

    @Test("spotlight file provider keeps generic card files below entity matches")
    func spotlightFileProviderKeepsGenericCardFilesBelowEntityMatches() async throws {
        let root = try temporaryDirectory()
        let genericCard = root.appendingPathComponent("Documents/Total/Alpha Soccer/card.psd")
        let alpha = root.appendingPathComponent("Documents/Total/alpha.psd")
        let casey = root.appendingPathComponent("Documents/Total/Keep/casey.psd")
        try createEmptyFile(at: genericCard)
        try createEmptyFile(at: casey)
        try createEmptyFile(at: alpha)

        let provider = SpotlightFileSearchProvider(
            home: root,
            spotlight: StubSpotlightSearch(urls: [genericCard, casey, alpha])
        )

        let results = await provider.search(
            query: "photoshop card for alpha and casey",
            refinements: [],
            limit: 5
        )

        #expect(results.prefix(2).map(\.title).sorted() == ["alpha.psd", "casey.psd"])
        #expect(results.last?.title == "card.psd")
    }

    @Test("spotlight file provider keeps soccer templates below named entity files")
    func spotlightFileProviderKeepsSoccerTemplatesBelowNamedEntityFiles() async throws {
        let root = try temporaryDirectory()
        let genericSoccer = root.appendingPathComponent("Documents/Total/Alpha Soccer/soccer.psd")
        let alpha = root.appendingPathComponent("Documents/Total/alpha.psd")
        try createEmptyFile(at: genericSoccer)
        try createEmptyFile(at: alpha)

        let provider = SpotlightFileSearchProvider(
            home: root,
            spotlight: StubSpotlightSearch(urls: [genericSoccer, alpha])
        )

        let results = await provider.search(
            query: "alpha soccer card photoshop",
            refinements: [],
            limit: 5
        )

        #expect(results.map(\.title) == ["alpha.psd", "soccer.psd"])
    }

    @Test("spotlight file provider keeps ramble context from outranking named png card")
    func spotlightFileProviderKeepsRambleContextFromOutrankingNamedPNGCard() async throws {
        let root = try temporaryDirectory()
        let card = root.appendingPathComponent("Documents/Total/alpha_card_edited_2.png")
        let duplicateCard = root.appendingPathComponent("Documents/Total/Total 2/alpha_card_edited_2.png")
        let avatar = root.appendingPathComponent("Developer/sampleproj/public/assets/alpha-avatar.png")
        let contextOnlyJunk = root.appendingPathComponent(
            "Library/Application Support/com.raycast.macos/RaycastWrapped/2025/sample-screenshot.png"
        )
        let soccerOnlyJunk = root.appendingPathComponent(
            "Downloads/Sample Art Folder/sample-card-art.png"
        )
        try createEmptyFile(at: contextOnlyJunk)
        try createEmptyFile(at: soccerOnlyJunk)
        try createEmptyFile(at: avatar)
        try createEmptyFile(at: duplicateCard)
        try createEmptyFile(at: card)
        try setModificationDate(Date(timeIntervalSince1970: 1_700_000_000), for: card)
        try setModificationDate(Date(timeIntervalSince1970: 1_800_000_000), for: contextOnlyJunk)

        let provider = SpotlightFileSearchProvider(
            home: root,
            spotlight: StubSpotlightSearch(urls: [contextOnlyJunk, soccerOnlyJunk, avatar, duplicateCard, card]),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let results = await provider.search(
            query: "alpha soccer card keep total gold numbers 85 png",
            refinements: [],
            limit: 5
        )

        #expect(results.first?.url == card)
        #expect(results.map(\.url).contains(card))
        #expect(!results.map(\.url).contains(contextOnlyJunk))
        #expect(!results.map(\.url).contains(soccerOnlyJunk))
    }

    @Test("spotlight file provider surfaces protected folder access gaps for file searches")
    func spotlightFileProviderSurfacesProtectedFolderAccessGapsForFileSearches() async throws {
        let root = try temporaryDirectory()
        let avatar = root.appendingPathComponent("Developer/sampleproj/public/assets/alpha-avatar.png")
        try createEmptyFile(at: avatar)
        let deniedDocuments = FileSearchAccessIssue(
            locationName: "Documents",
            path: root.appendingPathComponent("Documents").path,
            reason: "Operation not permitted"
        )
        let diagnostics = RememBarDiagnostics(
            directory: root.appendingPathComponent("Diagnostics", isDirectory: true),
            sessionID: "spotlight-access",
            now: IncrementingClock(start: Date(timeIntervalSince1970: 1_800_000_700)).nextDate,
            processID: 888,
            maxLogBytes: 200_000
        )
        _ = diagnostics.startSession()
        let provider = SpotlightFileSearchProvider(
            home: root,
            spotlight: StubSpotlightSearch(urls: [avatar]),
            accessChecker: StubFileSearchAccessChecker(issues: [deniedDocuments]),
            diagnostics: diagnostics
        )

        let response = await provider.searchResponse(query: "alpha soccer card png", refinements: [], limit: 5)

        #expect(response.results.first?.url == avatar)
        #expect(!response.results.contains { $0.kind == .systemSettings })
        #expect(response.sourceStatuses.contains {
            $0.id == "files.access.Documents" && $0.state == .blocked
        })
        let events = try diagnosticEvents(at: diagnostics.logURL)
        let accessEvent = events.first { $0.name == RememBarDiagnosticEvent.fileSearchAccessDenied }
        #expect(accessEvent?.fields["locationNames"] == "Documents")
        #expect(accessEvent?.fields["query"] == "alpha soccer card png")
    }

    @Test("spotlight provider reports file search status and access blocks")
    func spotlightProviderReportsStatuses() async throws {
        let root = try temporaryDirectory()
        let deniedDocuments = FileSearchAccessIssue(
            locationName: "Documents",
            path: root.appendingPathComponent("Documents").path,
            reason: "Permission denied"
        )
        let provider = SpotlightFileSearchProvider(
            home: root,
            spotlight: StubSpotlightSearch(urls: []),
            accessChecker: StubFileSearchAccessChecker(issues: [deniedDocuments])
        )

        let response = await provider.searchResponse(query: "alpha png", refinements: [], limit: 5)

        #expect(response.sourceStatuses.contains {
            $0.id == "files" && $0.state == .searched
        })
        #expect(response.sourceStatuses.contains {
            $0.id == "files.access.Documents" && $0.state == .blocked
        })
    }

    @Test("spotlight provider keeps file access blocks out of ranked results")
    func spotlightProviderKeepsAccessBlocksOutOfRankedResults() async throws {
        let root = try temporaryDirectory()
        let avatar = root.appendingPathComponent("Developer/sampleproj/public/assets/alpha-avatar.png")
        try createEmptyFile(at: avatar)
        let deniedDocuments = FileSearchAccessIssue(
            locationName: "Documents",
            path: root.appendingPathComponent("Documents").path,
            reason: "Operation not permitted"
        )
        let provider = SpotlightFileSearchProvider(
            home: root,
            spotlight: StubSpotlightSearch(urls: [avatar]),
            accessChecker: StubFileSearchAccessChecker(issues: [deniedDocuments])
        )

        let response = await provider.searchResponse(query: "alpha png", refinements: [], limit: 5)

        #expect(response.results.map(\.title) == ["alpha-avatar.png"])
        #expect(!response.results.contains { $0.kind == .systemSettings })
        #expect(response.sourceStatuses.contains { $0.state == .blocked })
    }

    @Test("source status display details sanitize raw paths and backend errors")
    func sourceStatusDisplayDetailsSanitizeRawPathsAndBackendErrors() {
        let status = MemorySearchSourceStatus(
            id: "history.safari",
            sourceName: "Safari",
            state: .failed,
            detail: "SQLite error 26 at /Users/example/Library/Safari/History.db: file is not a database"
        )

        #expect(status.displayDetail == "Could not read this source")
        #expect(!status.displayDetail.contains("/Users/example"))
        #expect(!status.accessibilityDetail.contains("History.db"))
    }

    @Test("spotlight file provider keeps access warning below the result limit when concrete files fill the page")
    func spotlightFileProviderKeepsAccessWarningBelowResultLimitWhenConcreteFilesFillThePage() async throws {
        let root = try temporaryDirectory()
        let first = root.appendingPathComponent("Documents/alpha-a.png")
        let second = root.appendingPathComponent("Documents/alpha-b.png")
        try createEmptyFile(at: first)
        try createEmptyFile(at: second)
        let deniedDocuments = FileSearchAccessIssue(
            locationName: "Documents",
            path: root.appendingPathComponent("Documents").path,
            reason: "Operation not permitted"
        )
        let provider = SpotlightFileSearchProvider(
            home: root,
            spotlight: StubSpotlightSearch(urls: [first, second]),
            accessChecker: StubFileSearchAccessChecker(issues: [deniedDocuments])
        )

        let results = await provider.search(query: "alpha png", refinements: [], limit: 2)

        #expect(results.map(\.kind) == [.file, .file])
    }

    @Test("spotlight file provider does not show protected folder warning for non-file searches")
    func spotlightFileProviderDoesNotShowProtectedFolderWarningForNonFileSearches() async throws {
        let root = try temporaryDirectory()
        let deniedDocuments = FileSearchAccessIssue(
            locationName: "Documents",
            path: root.appendingPathComponent("Documents").path,
            reason: "Operation not permitted"
        )
        let provider = SpotlightFileSearchProvider(
            home: root,
            spotlight: StubSpotlightSearch(urls: []),
            accessChecker: StubFileSearchAccessChecker(issues: [deniedDocuments])
        )

        let results = await provider.search(query: "workflow meeting", refinements: [], limit: 5)

        #expect(results.isEmpty)
    }

    @Test("spotlight file provider does not treat generic content words as file access intent")
    func spotlightFileProviderDoesNotTreatGenericContentWordsAsFileAccessIntent() async throws {
        let root = try temporaryDirectory()
        let deniedDocuments = FileSearchAccessIssue(
            locationName: "Documents",
            path: root.appendingPathComponent("Documents").path,
            reason: "Operation not permitted"
        )
        let provider = SpotlightFileSearchProvider(
            home: root,
            spotlight: StubSpotlightSearch(urls: []),
            accessChecker: StubFileSearchAccessChecker(issues: [deniedDocuments])
        )

        let results = await provider.search(query: "birthday card design ideas", refinements: [], limit: 5)

        #expect(results.isEmpty)
    }

    @Test("spotlight file provider prefers original path over newer duplicate copy")
    func spotlightFileProviderPrefersOriginalPathOverNewerDuplicateCopy() async throws {
        let root = try temporaryDirectory()
        let original = root.appendingPathComponent("Documents/Total/alpha.psd")
        let copy = root.appendingPathComponent("Documents/Total/Total 2/alpha.psd")
        try createEmptyFile(at: original)
        try createEmptyFile(at: copy)
        try setModificationDate(Date(timeIntervalSince1970: 1_700_000_000), for: original)
        try setModificationDate(Date(timeIntervalSince1970: 1_800_000_000), for: copy)

        let provider = SpotlightFileSearchProvider(
            home: root,
            spotlight: StubSpotlightSearch(urls: [copy, original])
        )

        let results = await provider.search(query: "alpha photoshop", refinements: [], limit: 5)

        #expect(results.map(\.url) == [original])
    }

    @Test("spotlight file provider uses injected now for deterministic recency")
    func spotlightFileProviderUsesInjectedNowForDeterministicRecency() async throws {
        let root = try temporaryDirectory()
        let old = root.appendingPathComponent("Documents/Total/alpha-a.psd")
        let recent = root.appendingPathComponent("Documents/Total/alpha-b.psd")
        try createEmptyFile(at: old)
        try createEmptyFile(at: recent)
        try setModificationDate(Date(timeIntervalSince1970: 1_700_000_000), for: old)
        try setModificationDate(Date(timeIntervalSince1970: 1_800_000_000), for: recent)

        let provider = SpotlightFileSearchProvider(
            home: root,
            spotlight: StubSpotlightSearch(urls: [old, recent]),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let results = await provider.search(query: "alpha photoshop", refinements: [], limit: 5)

        #expect(results.map(\.url) == [recent, old])
    }

    @Test("composite memory search provider merges providers by result rank")
    func compositeMemorySearchProviderMergesProvidersByResultRank() async {
        let web = MemoryResult(
            id: "web",
            title: "Alpha web page",
            detail: "Zen · Jun 27 · example.com",
            refinedDetail: nil,
            url: URL(string: "https://example.com/alpha")!,
            thumbnailURL: nil,
            browser: .zen,
            rank: 80
        )
        let file = MemoryResult(
            fileURL: URL(fileURLWithPath: "/Users/example/Documents/alpha.psd"),
            displayPath: "Documents/alpha.psd",
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_000),
            rank: 220
        )
        let provider = CompositeMemorySearchProvider(providers: [
            StaticMemorySearchProvider(results: [web]),
            StaticMemorySearchProvider(results: [file])
        ])

        let results = await provider.search(query: "alpha", refinements: [], limit: 2)

        #expect(results.map(\.id) == [file.id, web.id])
    }

    @Test("composite memory search provider keeps highest ranked duplicate id")
    func compositeMemorySearchProviderKeepsHighestRankedDuplicateID() async {
        let lowRank = MemoryResult(
            id: "same-id",
            title: "Lower rank",
            detail: "Zen · Jun 27 · example.com",
            refinedDetail: nil,
            url: URL(string: "https://example.com/low")!,
            thumbnailURL: nil,
            browser: .zen,
            rank: 20
        )
        let highRank = MemoryResult(
            id: "same-id",
            title: "Higher rank",
            detail: "Zen · Jun 27 · example.com",
            refinedDetail: nil,
            url: URL(string: "https://example.com/high")!,
            thumbnailURL: nil,
            browser: .zen,
            rank: 90
        )
        let provider = CompositeMemorySearchProvider(providers: [
            StaticMemorySearchProvider(results: [lowRank]),
            StaticMemorySearchProvider(results: [highRank])
        ])

        let results = await provider.search(query: "same", refinements: [], limit: 5)

        #expect(results == [highRank])
    }

    @Test("composite memory search provider uses deterministic tie breakers for duplicate ids")
    func compositeMemorySearchProviderUsesDeterministicTieBreakersForDuplicateIDs() async {
        let zURL = MemoryResult(
            id: "same-id",
            title: "Same title",
            detail: "Zen · Jun 27 · example.com",
            refinedDetail: nil,
            url: URL(string: "https://example.com/z")!,
            thumbnailURL: nil,
            browser: .zen,
            rank: 90
        )
        let aURL = MemoryResult(
            id: "same-id",
            title: "Same title",
            detail: "Zen · Jun 27 · example.com",
            refinedDetail: nil,
            url: URL(string: "https://example.com/a")!,
            thumbnailURL: nil,
            browser: .zen,
            rank: 90
        )
        let provider = CompositeMemorySearchProvider(providers: [
            StaticMemorySearchProvider(results: [zURL]),
            StaticMemorySearchProvider(results: [aURL])
        ])

        let results = await provider.search(query: "same", refinements: [], limit: 5)

        #expect(results == [aURL])
    }

    @Test("composite memory search provider sorts equal rank and title deterministically")
    func compositeMemorySearchProviderSortsEqualRankAndTitleDeterministically() async {
        let b = MemoryResult(
            id: "b",
            title: "Same title",
            detail: "Zen · Jun 27 · example.com",
            refinedDetail: nil,
            url: URL(string: "https://example.com/b")!,
            thumbnailURL: nil,
            browser: .zen,
            rank: 90
        )
        let a = MemoryResult(
            id: "a",
            title: "Same title",
            detail: "Zen · Jun 27 · example.com",
            refinedDetail: nil,
            url: URL(string: "https://example.com/a")!,
            thumbnailURL: nil,
            browser: .zen,
            rank: 90
        )
        let provider = CompositeMemorySearchProvider(providers: [
            StaticMemorySearchProvider(results: [b]),
            StaticMemorySearchProvider(results: [a])
        ])

        let results = await provider.search(query: "same", refinements: [], limit: 5)

        #expect(results == [a, b])
    }

    @Test("composite search response merges provider statuses with ranked results")
    func compositeSearchResponseMergesStatuses() async {
        let highRank = MemoryResult(
            id: "workflow",
            title: "Workflow",
            detail: "Files · match",
            refinedDetail: nil,
            url: URL(string: "https://example.com/workflow")!,
            thumbnailURL: nil,
            browser: .zen,
            rank: 90
        )
        let lowRank = MemoryResult(
            id: "claude-design",
            title: "Claude Design",
            detail: "Safari · match",
            refinedDetail: nil,
            url: URL(string: "https://example.com/claude-design")!,
            thumbnailURL: nil,
            browser: .safari,
            rank: 40
        )
        let provider = CompositeMemorySearchProvider(providers: [
            StaticResponseMemorySearchProvider(response: MemorySearchResponse(
                results: [highRank],
                sourceStatuses: [
                    MemorySearchSourceStatus(
                        id: "files",
                        sourceName: "Files",
                        state: .searched,
                        detail: "1 match"
                    )
                ]
            )),
            StaticResponseMemorySearchProvider(response: MemorySearchResponse(
                results: [lowRank],
                sourceStatuses: [
                    MemorySearchSourceStatus(
                        id: "safari",
                        sourceName: "Safari",
                        state: .blocked,
                        detail: "Authorization denied"
                    )
                ]
            ))
        ])

        let response = await provider.searchResponse(query: "workflow", refinements: [], limit: 5)

        #expect(response.results.map(\.id) == ["workflow", "claude-design"])
        #expect(response.sourceStatuses.map(\.id) == ["files", "safari"])
        #expect(response.sourceStatuses.last?.state == .blocked)
    }

    @Test("composite search response orders statuses by provider order and keeps most severe duplicate")
    func compositeSearchResponseOrdersStatusesByProviderOrderAndSeverity() async {
        let provider = CompositeMemorySearchProvider(providers: [
            DelayedResponseMemorySearchProvider(
                delay: .milliseconds(80),
                response: MemorySearchResponse(sourceStatuses: [
                    MemorySearchSourceStatus(
                        id: "history",
                        sourceName: "Browser History",
                        state: .blocked,
                        detail: "Authorization denied"
                    )
                ])
            ),
            DelayedResponseMemorySearchProvider(
                delay: .milliseconds(10),
                response: MemorySearchResponse(sourceStatuses: [
                    MemorySearchSourceStatus(
                        id: "files",
                        sourceName: "Files",
                        state: .searched,
                        detail: "0 results"
                    ),
                    MemorySearchSourceStatus(
                        id: "history",
                        sourceName: "Browser History",
                        state: .searched,
                        detail: "0 visits"
                    )
                ])
            )
        ])

        let response = await provider.searchResponse(query: "anything", refinements: [], limit: 5)

        #expect(response.sourceStatuses.map(\.id) == ["history", "files"])
        #expect(response.sourceStatuses.first?.state == .blocked)
    }

    @Test("legacy search returns response results for compatibility")
    func legacySearchReturnsResponseResults() async {
        let provider = StaticResponseMemorySearchProvider(response: MemorySearchResponse(
            results: [MemoryResult.samples["workflow"]!],
            sourceStatuses: [
                MemorySearchSourceStatus(
                    id: "files",
                    sourceName: "Files",
                    state: .searched,
                    detail: "1 match"
                )
            ]
        ))

        let results = await provider.search(query: "workflow", refinements: [], limit: 5)

        #expect(results.map(\.id) == ["workflow"])
    }

    @Test("source status presentation exposes stable labels and icons")
    func sourceStatusPresentationExposesStableLabelsAndIcons() {
        let blocked = MemorySearchSourceStatus(
            id: "safari",
            sourceName: "Safari",
            state: .blocked,
            detail: "Authorization denied"
        )
        let searched = MemorySearchSourceStatus(
            id: "files",
            sourceName: "Files",
            state: .searched,
            detail: "2 results"
        )

        #expect(blocked.stateLabel == "Blocked")
        #expect(blocked.systemImageName == "lock.trianglebadge.exclamationmark")
        #expect(searched.stateLabel == "Searched")
        #expect(searched.systemImageName == "checkmark.circle")
    }

    @Test("one password provider matches item metadata without secret fields")
    func onePasswordProviderMatchesItemMetadataWithoutSecretFields() async {
        let provider = OnePasswordSearchProvider(itemLister: StubOnePasswordItemLister(result: .success([
            OnePasswordItemSummary(
                id: "facebook-item",
                title: "Facebook",
                vaultID: "private-vault",
                vaultName: "Private",
                category: "LOGIN"
            ),
            OnePasswordItemSummary(
                id: "notion-item",
                title: "Notion",
                vaultID: "work-vault",
                vaultName: "Work",
                category: "LOGIN"
            )
        ])))

        let response = await provider.searchResponse(query: "facebook recovery codes", refinements: [], limit: 5)

        #expect(response.results.map(\.title) == ["Facebook"])
        #expect(response.results.first?.detail == "1Password · Private · Login")
        #expect(response.results.first?.target.actionLabel == "Open 1Password")
        #expect(response.results.first?.target.copyValue == "onepassword://")
        #expect(response.sourceStatuses == [
            MemorySearchSourceStatus(
                id: "1password",
                sourceName: "1Password",
                state: .searched,
                detail: "2 visible items"
            )
        ])
    }

    @Test("one password provider reports unavailable and locked states")
    func onePasswordProviderReportsUnavailableAndLockedStates() async {
        let unavailable = await OnePasswordSearchProvider(
            itemLister: StubOnePasswordItemLister(result: .failure(.unavailable))
        ).searchResponse(query: "facebook", refinements: [], limit: 5)
        let locked = await OnePasswordSearchProvider(
            itemLister: StubOnePasswordItemLister(result: .failure(.locked))
        ).searchResponse(query: "facebook", refinements: [], limit: 5)

        #expect(unavailable.results.isEmpty)
        #expect(unavailable.sourceStatuses.first == MemorySearchSourceStatus(
            id: "1password",
            sourceName: "1Password",
            state: .unavailable,
            detail: "1Password CLI is not installed"
        ))
        #expect(locked.results.isEmpty)
        #expect(locked.sourceStatuses.first == MemorySearchSourceStatus(
            id: "1password",
            sourceName: "1Password",
            state: .blocked,
            detail: "Unlock or sign in to 1Password"
        ))
    }

    @Test("one password provider treats cancellation as skipped without failure diagnostics")
    func onePasswordProviderTreatsCancellationAsSkippedWithoutFailureDiagnostics() async throws {
        let diagnostics = RememBarDiagnostics(
            directory: try temporaryDirectory().appendingPathComponent("Diagnostics", isDirectory: true),
            sessionID: "onepassword-cancelled",
            now: IncrementingClock(start: Date(timeIntervalSince1970: 1_800_005_500)).nextDate,
            processID: 779,
            maxLogBytes: 200_000
        )
        _ = diagnostics.startSession()
        let provider = OnePasswordSearchProvider(
            itemLister: CancellingOnePasswordItemLister(),
            diagnostics: diagnostics
        )

        let response = await provider.searchResponse(query: "facebook", refinements: [], limit: 5)

        #expect(response.results.isEmpty)
        #expect(response.sourceStatuses.first == MemorySearchSourceStatus(
            id: "1password",
            sourceName: "1Password",
            state: .skipped,
            detail: "Search cancelled"
        ))
        #expect(try diagnosticEvents(at: diagnostics.logURL).contains {
            $0.name == RememBarDiagnosticEvent.onePasswordProviderFailed
        } == false)
    }

    @Test("one password provider does not log secret bearing error descriptions")
    func onePasswordProviderDoesNotLogSecretBearingErrorDescriptions() async throws {
        let diagnostics = RememBarDiagnostics(
            directory: try temporaryDirectory().appendingPathComponent("Diagnostics", isDirectory: true),
            sessionID: "onepassword-secret-safe-error",
            now: IncrementingClock(start: Date(timeIntervalSince1970: 1_800_005_000)).nextDate,
            processID: 778,
            maxLogBytes: 200_000
        )
        _ = diagnostics.startSession()
        let provider = OnePasswordSearchProvider(
            itemLister: ThrowingOnePasswordItemLister(),
            diagnostics: diagnostics
        )

        let response = await provider.searchResponse(query: "facebook recovery", refinements: [], limit: 5)

        #expect(response.results.isEmpty)
        #expect(response.sourceStatuses.first == MemorySearchSourceStatus(
            id: "1password",
            sourceName: "1Password",
            state: .failed,
            detail: "Could not read item metadata"
        ))
        let event = try #require(try diagnosticEvents(at: diagnostics.logURL).first {
            $0.name == RememBarDiagnosticEvent.onePasswordProviderFailed
        })
        #expect(event.fields["error"] == nil)
        #expect(event.fields["errorType"]?.isEmpty == false)
        #expect(event.fields.values.contains { $0.contains(SensitiveOnePasswordError.secretText) } == false)
    }

    @Test("one password cli parser reads only safe metadata fields")
    func onePasswordCLIParserReadsOnlySafeMetadataFields() throws {
        let data = Data("""
        [
          {
            "id": "facebook-item",
            "title": "Facebook",
            "vault": {"id": "private-vault", "name": "Private"},
            "category": "LOGIN",
            "fields": [{"label": "password", "value": "do-not-read"}]
          }
        ]
        """.utf8)

        let items = try OnePasswordCLIItemLister.decodeItems(from: data)

        #expect(items == [
            OnePasswordItemSummary(
                id: "facebook-item",
                title: "Facebook",
                vaultID: "private-vault",
                vaultName: "Private",
                category: "LOGIN"
            )
        ])
    }

    @Test("one password cli lister invokes metadata list command only")
    func onePasswordCLIListerInvokesMetadataListCommandOnly() async throws {
        let root = try temporaryDirectory()
        let argsURL = root.appendingPathComponent("args.txt")
        let scriptURL = try writeExecutableShellScript("""
        #!/bin/sh
        printf '%s\\n' "$@" > \(shellSingleQuoted(argsURL.path))
        printf '[{"id":"facebook-item","title":"Facebook","vault":{"id":"private-vault","name":"Private"},"category":"LOGIN"}]'
        """)
        let lister = OnePasswordCLIItemLister(executableURL: scriptURL, timeout: .seconds(2))

        let items = try await lister.listItems()
        let args = try String(contentsOf: argsURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)

        #expect(args == ["item", "list", "--format", "json"])
        #expect(args.contains("get") == false)
        #expect(items.map(\.title) == ["Facebook"])
    }

    @Test("one password cli lister drains large output while command is running")
    func onePasswordCLIListerDrainsLargeOutputWhileCommandIsRunning() async throws {
        let scriptURL = try writeExecutableShellScript("""
        #!/bin/sh
        printf '['
        i=0
        while [ "$i" -lt 2500 ]; do
          if [ "$i" -gt 0 ]; then
            printf ','
          fi
          printf '{"id":"item-%s","title":"Facebook %s","vault":{"id":"private-vault","name":"Private"},"category":"LOGIN"}' "$i" "$i"
          i=$((i + 1))
        done
        printf ']'
        """)
        let lister = OnePasswordCLIItemLister(executableURL: scriptURL, timeout: .seconds(2))

        let items = try await lister.listItems()

        #expect(items.count == 2500)
        #expect(items.first?.title == "Facebook 0")
        #expect(items.last?.title == "Facebook 2499")
    }

    @Test("one password cli lister terminates process when task is cancelled")
    func onePasswordCLIListerTerminatesProcessWhenTaskIsCancelled() async throws {
        let root = try temporaryDirectory()
        let startedURL = root.appendingPathComponent("started.txt")
        let terminatedURL = root.appendingPathComponent("terminated.txt")
        let scriptURL = try writeExecutableShellScript("""
        #!/bin/sh
        trap 'printf terminated > \(shellSingleQuoted(terminatedURL.path)); exit 143' TERM
        printf started > \(shellSingleQuoted(startedURL.path))
        while true; do
          sleep 1
        done
        """)
        let lister = OnePasswordCLIItemLister(executableURL: scriptURL, timeout: .seconds(2))

        let task = Task {
            try await lister.listItems()
        }
        let started = await eventually {
            FileManager.default.fileExists(atPath: startedURL.path)
        }
        try #require(started)
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("cancelled 1Password list task unexpectedly returned items")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("cancelled 1Password list task threw \(error) instead of CancellationError")
        }
        let terminated = await eventually {
            FileManager.default.fileExists(atPath: terminatedURL.path)
        }
        #expect(terminated)
    }

    @Test("memory search store copies file paths and opens result targets")
    @MainActor
    func memorySearchStoreCopiesFilePathsAndOpensResultTargets() {
        let opener = RecordingMemoryResultOpener()
        let fileURL = URL(fileURLWithPath: "/Users/example/Documents/alpha.psd")
        let result = MemoryResult(
            fileURL: fileURL,
            displayPath: "Documents/alpha.psd",
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_000),
            rank: 220
        )
        let store = MemorySearchStore(
            searchProvider: StaticMemorySearchProvider(results: []),
            resultOpener: opener
        )

        store.select(result)
        store.open(result)

        #expect(NSPasteboard.general.string(forType: .string) == fileURL.path)
        #expect(opener.opened == [result])
    }

    @Test("memory result targets expose source-specific action labels")
    func memoryResultTargetsExposeSourceSpecificActionLabels() throws {
        let web = MemoryResultTarget.web(url: URL(string: "https://example.com")!, browser: .zen)
        let file = MemoryResultTarget.file(URL(fileURLWithPath: "/Users/example/Documents/alpha.psd"))
        let settings = MemoryResultTarget.systemSettings(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
        let onePasswordTarget = try #require(ExternalAppTarget.onePassword())
        let external = MemoryResultTarget.externalApp(onePasswordTarget)

        #expect(web.actionLabel == "Open")
        #expect(file.actionLabel == "Show in Finder")
        #expect(settings.actionLabel == "Open Settings")
        #expect(external.actionLabel == "Open 1Password")
        #expect(external.copyValue == "onepassword://")
        #expect(ExternalAppTarget.onePassword(url: URL(string: "https://example.com")!) == nil)
    }

    @Test("memory result kind classifies files without thumbnail view guards")
    func memoryResultKindClassifiesFilesWithoutThumbnailViewGuards() throws {
        let file = MemoryResult(
            fileURL: URL(fileURLWithPath: "/Users/example/Documents/alpha.psd"),
            displayPath: "Documents/alpha.psd",
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_000),
            rank: 220
        )
        let web = MemoryResult(
            id: "web",
            title: "Video",
            detail: "Zen · Jun 27 · youtube.com",
            refinedDetail: nil,
            url: URL(string: "https://www.youtube.com/watch?v=abc123")!,
            thumbnailURL: nil,
            browser: .zen,
            rank: 80
        )
        let external = MemoryResult(
            id: "onepassword|item",
            title: "Facebook",
            detail: "1Password · Private · Login",
            externalApp: try #require(ExternalAppTarget.onePassword()),
            rank: 80
        )

        #expect(file.kind == .file)
        #expect(web.kind == .youtubeVideo(id: "abc123"))
        #expect(external.kind == .externalApp)
        #expect(MemoryResult(
            id: "settings",
            title: "Settings",
            detail: "Open Settings",
            systemSettingsURL: FileSearchAccessIssue.fullDiskAccessSettingsURL
        ).kind == .systemSettings)
    }

    @Test("thumbnail presentation has a dedicated system settings fallback")
    func thumbnailPresentationHasDedicatedSystemSettingsFallback() {
        let result = MemoryResult(
            id: "settings",
            title: "Settings",
            detail: "Open Settings",
            systemSettingsURL: FileSearchAccessIssue.fullDiskAccessSettingsURL
        )

        let presentation = MemoryThumbnailPresentation(result: result)

        #expect(presentation.source == .fallback)
        #expect(presentation.fallback == .systemSettings)
    }

    @Test("protected location access checker classifies only permission errors as actionable")
    func protectedLocationAccessCheckerClassifiesOnlyPermissionErrorsAsActionable() {
        let permissionError = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        let wrappedPermissionError = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileReadNoPermissionError,
            userInfo: [NSUnderlyingErrorKey: permissionError]
        )
        let missingFileError = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)

        #expect(ProtectedLocationFileSearchAccessChecker.isPermissionDenied(wrappedPermissionError))
        #expect(!ProtectedLocationFileSearchAccessChecker.isPermissionDenied(missingFileError))
    }

    @Test("memory result thumbnails distinguish remote images from file previews")
    func memoryResultThumbnailsDistinguishRemoteImagesFromFilePreviews() {
        let thumbnailURL = URL(string: "https://img.youtube.com/vi/abc123/hqdefault.jpg")!
        let fileURL = URL(fileURLWithPath: "/Users/example/Documents/alpha.psd")
        let web = MemoryResult(
            id: "web",
            title: "Video",
            detail: "Zen · Jun 27 · youtube.com",
            refinedDetail: nil,
            url: URL(string: "https://www.youtube.com/watch?v=abc123")!,
            thumbnailURL: thumbnailURL,
            browser: .zen,
            rank: 80
        )
        let file = MemoryResult(
            fileURL: fileURL,
            displayPath: "Documents/alpha.psd",
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_000),
            rank: 220
        )

        #expect(web.thumbnail == .remoteImage(thumbnailURL))
        #expect(file.thumbnail == .filePreview(fileURL))
        #expect(web.thumbnailURL == thumbnailURL)
        #expect(file.thumbnailURL == nil)
    }

    @Test("memory result kind maps youtube container web targets")
    func memoryResultKindMapsYouTubeContainerWebTargets() {
        let cases: [(URL, MemoryResultKind)] = [
            (URL(string: "https://www.youtube.com/results?search_query=cold+ones")!, .youtubeSearch(query: "cold ones")),
            (URL(string: "https://www.youtube.com/@coldones/videos")!, .youtubeChannel(label: "@coldones")),
            (URL(string: "https://www.youtube.com/playlist?list=PL123")!, .youtubePlaylist),
            (URL(string: "https://www.youtube.com/")!, .youtubeHome),
            (URL(string: "https://example.com/")!, .web)
        ]

        for (url, kind) in cases {
            let result = MemoryResult(
                id: url.absoluteString,
                title: "Result",
                detail: "Zen · Jun 27 · \(url.host() ?? "")",
                refinedDetail: nil,
                url: url,
                thumbnailURL: nil,
                browser: .zen,
                rank: 1
            )

            #expect(result.kind == kind)
        }
    }

    @Test("mdfind spotlight search times out stuck processes")
    func mdfindSpotlightSearchTimesOutStuckProcesses() async throws {
        let root = try temporaryDirectory()
        let script = root.appendingPathComponent("sleeping-mdfind")
        try createTextFile(at: script, contents: "#!/bin/sh\nsleep 2\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let spotlight = MdfindSpotlightSearch(
            executableURL: script,
            timeout: .milliseconds(100)
        )

        do {
            _ = try await spotlight.search(query: "anything", root: root)
            Issue.record("Expected mdfind timeout")
        } catch SpotlightSearchError.timedOut {
        }
    }

    @Test("mdfind spotlight search cancels running processes")
    func mdfindSpotlightSearchCancelsRunningProcesses() async throws {
        let root = try temporaryDirectory()
        let script = root.appendingPathComponent("sleeping-mdfind")
        try createTextFile(at: script, contents: "#!/bin/sh\nsleep 3\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let spotlight = MdfindSpotlightSearch(
            executableURL: script,
            timeout: .seconds(10)
        )
        let startedAt = Date()
        let task = Task {
            try await spotlight.search(query: "anything", root: root)
        }

        try await Task.sleep(for: .milliseconds(100))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected mdfind cancellation")
        } catch is CancellationError {
        }
        #expect(Date().timeIntervalSince(startedAt) < 1)
    }

    @Test("mdfind spotlight search handles immediate cancellation before launch")
    func mdfindSpotlightSearchHandlesImmediateCancellationBeforeLaunch() async throws {
        let root = try temporaryDirectory()
        let script = root.appendingPathComponent("sleeping-mdfind")
        try createTextFile(at: script, contents: "#!/bin/sh\nsleep 3\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let spotlight = MdfindSpotlightSearch(
            executableURL: script,
            timeout: .seconds(10)
        )
        let task = Task {
            try await spotlight.search(query: "anything", root: root)
        }

        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected immediate mdfind cancellation")
        } catch is CancellationError {
        }
    }

    @Test("mdfind spotlight search does not leak pipes when launch fails")
    func mdfindSpotlightSearchDoesNotLeakPipesWhenLaunchFails() async throws {
        let root = try temporaryDirectory()
        let missingExecutable = root.appendingPathComponent("missing-mdfind")
        let spotlight = MdfindSpotlightSearch(
            executableURL: missingExecutable,
            timeout: .seconds(1)
        )
        let openDescriptorsBefore = try openFileDescriptorCount()

        for _ in 0..<12 {
            do {
                _ = try await spotlight.search(query: "anything", root: root)
                Issue.record("Expected mdfind launch failure")
            } catch {
            }
        }

        let returnedToBaseline = await eventually(attempts: 100, interval: .milliseconds(20)) {
            guard let openDescriptorsAfter = try? openFileDescriptorCount() else { return false }
            return openDescriptorsAfter <= openDescriptorsBefore + 8
        }
        let openDescriptorsAfter = try openFileDescriptorCount()
        #expect(returnedToBaseline, "open descriptors after launch failures: \(openDescriptorsAfter), before: \(openDescriptorsBefore)")
    }

    @Test("mdfind spotlight search logs launch failures with executable and query")
    func mdfindSpotlightSearchLogsLaunchFailuresWithExecutableAndQuery() async throws {
        let root = try temporaryDirectory()
        let missingExecutable = root.appendingPathComponent("missing-mdfind")
        let diagnostics = RememBarDiagnostics(
            directory: root.appendingPathComponent("Diagnostics", isDirectory: true),
            sessionID: "mdfind-launch",
            now: IncrementingClock(start: Date(timeIntervalSince1970: 1_800_000_700)).nextDate,
            processID: 888,
            maxLogBytes: 200_000
        )
        _ = diagnostics.startSession()
        let spotlight = MdfindSpotlightSearch(
            executableURL: missingExecutable,
            timeout: .seconds(1),
            diagnostics: diagnostics
        )

        do {
            _ = try await spotlight.search(query: "kMDItemFSName == '*alpha*'", root: root)
            Issue.record("Expected mdfind launch failure")
        } catch {
        }

        let events = try diagnosticEvents(at: diagnostics.logURL)
        let failure = events.first { $0.name == "mdfind.process.launch.failed" }
        #expect(failure?.fields["executable"] == missingExecutable.path)
        #expect(failure?.fields["root"] == root.path)
        #expect(failure?.fields["query"] == "kMDItemFSName == '*alpha*'")
        #expect(failure?.fields["error"]?.isEmpty == false)
    }
}

private func openFileDescriptorCount() throws -> Int {
    try FileManager.default.contentsOfDirectory(atPath: "/dev/fd")
        .filter { Int($0) != nil }
        .count
}

private func createEmptyFile(at url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: url.path, contents: Data())
}

private func createTextFile(at url: URL, contents: String) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try contents.write(to: url, atomically: true, encoding: .utf8)
}

private func setModificationDate(_ date: Date, for url: URL) throws {
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
}

private struct ChromiumHistoryFixture {
    let title: String
    let url: String
    let visitTime: Int64
}

private struct FirefoxHistoryFixture {
    let title: String
    let url: String
    let visitDate: Int64
}

private func createChromiumHistory(at url: URL, title: String, url pageURL: String, visitTime: Int64) throws {
    try createChromiumHistory(
        at: url,
        rows: [ChromiumHistoryFixture(title: title, url: pageURL, visitTime: visitTime)]
    )
}

private func createChromiumHistory(at url: URL, rows: [ChromiumHistoryFixture]) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK else {
        throw TestSQLiteError.open
    }
    defer { sqlite3_close(database) }

    let inserts = rows.enumerated().map { index, row in
        let id = index + 1
        let escapedTitle = row.title.replacingOccurrences(of: "'", with: "''")
        let escapedURL = row.url.replacingOccurrences(of: "'", with: "''")
        return """
        INSERT INTO urls VALUES(\(id), '\(escapedURL)', '\(escapedTitle)', 1);
        INSERT INTO visits VALUES(\(id), \(id), \(row.visitTime));
        """
    }.joined(separator: "\n")
    let sql = """
        CREATE TABLE urls(id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER);
        CREATE TABLE visits(id INTEGER PRIMARY KEY, url INTEGER, visit_time INTEGER);
        \(inserts)
        """
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
        throw TestSQLiteError.exec
    }
}

private func createFirefoxHistory(at url: URL, rows: [FirefoxHistoryFixture]) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK else {
        throw TestSQLiteError.open
    }
    defer { sqlite3_close(database) }

    let inserts = rows.enumerated().map { index, row in
        let id = index + 1
        let escapedTitle = row.title.replacingOccurrences(of: "'", with: "''")
        let escapedURL = row.url.replacingOccurrences(of: "'", with: "''")
        return """
        INSERT INTO moz_places VALUES(\(id), '\(escapedURL)', '\(escapedTitle)');
        INSERT INTO moz_historyvisits VALUES(\(id), \(id), \(row.visitDate));
        """
    }.joined(separator: "\n")
    let sql = """
        CREATE TABLE moz_places(id INTEGER PRIMARY KEY, url TEXT, title TEXT);
        CREATE TABLE moz_historyvisits(id INTEGER PRIMARY KEY, place_id INTEGER, visit_date INTEGER);
        \(inserts)
        """
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
        throw TestSQLiteError.exec
    }
}

private func createSafariHistory(at url: URL, title: String, url pageURL: String, visitTime: Double) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK else {
        throw TestSQLiteError.open
    }
    defer { sqlite3_close(database) }

    let escapedTitle = title.replacingOccurrences(of: "'", with: "''")
    let escapedURL = pageURL.replacingOccurrences(of: "'", with: "''")
    let sql = """
        CREATE TABLE history_items(id INTEGER PRIMARY KEY, url TEXT);
        CREATE TABLE history_visits(id INTEGER PRIMARY KEY, history_item INTEGER, visit_time REAL, title TEXT);
        INSERT INTO history_items VALUES(1, '\(escapedURL)');
        INSERT INTO history_visits VALUES(1, 1, \(visitTime), '\(escapedTitle)');
        """
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
        throw TestSQLiteError.exec
    }
}

private enum TestSQLiteError: Error {
    case open
    case exec
}

private final class ThreadRecordingSearchProvider: MemorySearching, @unchecked Sendable {
    private let lock = NSLock()
    private var _didRun = false
    private var _ranOnMainThread: Bool?

    var didRun: Bool {
        lock.withLock { _didRun }
    }

    var ranOnMainThread: Bool? {
        lock.withLock { _ranOnMainThread }
    }

    func searchResponse(query: String, refinements: [String], limit: Int) async -> MemorySearchResponse {
        lock.withLock {
            _didRun = true
            _ranOnMainThread = Thread.isMainThread
        }
        return MemorySearchResponse(results: [])
    }
}

private struct RecordedSearchRequest: Equatable {
    let query: String
    let refinements: [String]
}

private final class RequestRecordingSearchProvider: MemorySearching, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [RecordedSearchRequest] = []

    var requests: [RecordedSearchRequest] {
        lock.withLock { _requests }
    }

    func searchResponse(query: String, refinements: [String], limit: Int) async -> MemorySearchResponse {
        lock.withLock {
            _requests.append(RecordedSearchRequest(query: query, refinements: refinements))
        }
        return MemorySearchResponse(results: Array(MemoryResult.samples.values.prefix(limit)))
    }
}

private struct StubSpotlightSearch: SpotlightSearching, Sendable {
    let urls: [URL]

    func search(query: String, root: URL) async throws -> [URL] {
        urls
    }
}

private struct StubFileSearchAccessChecker: FileSearchAccessChecking {
    let issues: [FileSearchAccessIssue]

    func inaccessibleLocations(home: URL) -> [FileSearchAccessIssue] {
        issues
    }
}

private struct ThrowingSpotlightSearch: SpotlightSearching, Sendable {
    func search(query: String, root: URL) async throws -> [URL] {
        throw TestSpotlightError.forcedFailure
    }
}

private enum TestSpotlightError: Error, CustomStringConvertible {
    case forcedFailure

    var description: String {
        "forced spotlight failure"
    }
}

private struct EmptyCrashReportScanner: RememBarCrashReportScanning {
    func reports(since: Date?, processID: Int32?) -> [RememBarCrashReportSummary] {
        []
    }
}

private struct StaticMemorySearchProvider: MemorySearching, Sendable {
    let results: [MemoryResult]

    func searchResponse(query: String, refinements: [String], limit: Int) async -> MemorySearchResponse {
        MemorySearchResponse(results: Array(results.prefix(limit)))
    }
}

private struct StaticResponseMemorySearchProvider: MemorySearching, Sendable {
    let response: MemorySearchResponse

    func searchResponse(query: String, refinements: [String], limit: Int) async -> MemorySearchResponse {
        MemorySearchResponse(
            results: Array(response.results.prefix(limit)),
            sourceStatuses: response.sourceStatuses
        )
    }
}

private struct DelayedResponseMemorySearchProvider: MemorySearching, Sendable {
    let delay: Duration
    let response: MemorySearchResponse

    func searchResponse(query: String, refinements: [String], limit: Int) async -> MemorySearchResponse {
        try? await Task.sleep(for: delay)
        return MemorySearchResponse(
            results: Array(response.results.prefix(limit)),
            sourceStatuses: response.sourceStatuses
        )
    }
}

private struct StubOnePasswordItemLister: OnePasswordItemListing {
    let result: Result<[OnePasswordItemSummary], OnePasswordItemListError>

    func listItems() async throws -> [OnePasswordItemSummary] {
        try result.get()
    }
}

private struct ThrowingOnePasswordItemLister: OnePasswordItemListing {
    func listItems() async throws -> [OnePasswordItemSummary] {
        throw SensitiveOnePasswordError()
    }
}

private struct CancellingOnePasswordItemLister: OnePasswordItemListing {
    func listItems() async throws -> [OnePasswordItemSummary] {
        throw CancellationError()
    }
}

private struct SensitiveOnePasswordError: Error, CustomStringConvertible {
    static let secretText = "do-not-log-secret-recovery-code"

    var description: String {
        Self.secretText
    }
}

private func writeExecutableShellScript(_ contents: String) throws -> URL {
    let url = try temporaryDirectory().appendingPathComponent("script.sh")
    try contents.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

private func shellSingleQuoted(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}

@MainActor
private final class RecordingMemoryResultOpener: MemoryResultOpening {
    private(set) var opened: [MemoryResult] = []

    func open(_ result: MemoryResult) {
        opened.append(result)
    }
}
