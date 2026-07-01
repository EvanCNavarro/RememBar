import AppKit
@testable import BrowserMemoryBar
import Foundation
import SQLite3
import Testing

// swiftlint:disable file_length
// This suite intentionally colocates diagnostics, crash-scanner, and menu-bar-placement tests;
// splitting is out of scope, so the file/type body exceed the default budgets.
// swiftlint:disable type_body_length line_length
// line_length: the crash-report string-literal fixtures (symbolicated stack frames, packed IPS JSON
// lines) must stay byte-exact for the parser under test, so the two >120-char lines inside those
// literals cannot be reflowed. The paired `enable` at end-of-file keeps these scoped, not blanket.

@Suite("Diagnostics")
struct DiagnosticsTests {
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
}
// swiftlint:enable type_body_length line_length
