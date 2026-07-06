// Cohesive end-to-end suite; splitting fragments scenarios, so the file/type length limits are relaxed here.
// swiftlint:disable file_length type_body_length
import AppKit
@testable import BrowserMemoryBar
import Foundation
import SQLite3
import Testing

@Suite("Integration")
struct IntegrationTests {
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
        let resultB = MemoryResult(
            id: "b",
            title: "Same title",
            detail: "Zen · Jun 27 · example.com",
            refinedDetail: nil,
            url: URL(string: "https://example.com/b")!,
            thumbnailURL: nil,
            browser: .zen,
            rank: 90
        )
        let resultA = MemoryResult(
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
            StaticMemorySearchProvider(results: [resultB]),
            StaticMemorySearchProvider(results: [resultA])
        ])

        let results = await provider.search(query: "same", refinements: [], limit: 5)

        #expect(results == [resultA, resultB])
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

    @Test("one password provider expands the query through alias groups")
    func onePasswordProviderExpandsAliases() async {
        let items: [OnePasswordItemSummary] = [
            OnePasswordItemSummary(
                id: "ecn",
                title: "ECN Portal",
                vaultID: "v",
                vaultName: "Private",
                category: "LOGIN"
            )
        ]
        // evan→ecn alias: searching "evan" finds the ECN item it otherwise wouldn't.
        let aliased = OnePasswordSearchProvider(
            itemLister: StubOnePasswordItemLister(result: .success(items)),
            aliases: AliasGroups(groups: [["evan", "ecn"]])
        )
        let aliasedTitles = await aliased.searchResponse(query: "evan", refinements: [], limit: 5).results.map(\.title)
        #expect(aliasedTitles == ["ECN Portal"])

        // Without the alias, "evan" matches nothing in "ECN Portal".
        let plain = OnePasswordSearchProvider(itemLister: StubOnePasswordItemLister(result: .success(items)))
        #expect(await plain.searchResponse(query: "evan", refinements: [], limit: 5).results.isEmpty)
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
        printf '[{"id":"facebook-item","title":"Facebook",'
        printf '"vault":{"id":"private-vault","name":"Private"},"category":"LOGIN"}]'
        """)
        // Generous hang-guard, NOT an SLA — the suite's process-spawn is itself load-sensitive, so even
        // a 1-item list can race a 2s ceiling under saturation (same false-fail class as the 2500-item test).
        let lister = OnePasswordCLIItemLister(executableURL: scriptURL, timeout: .seconds(30))

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
          printf '{"id":"item-%s","title":"Facebook %s",' "$i" "$i"
          printf '"vault":{"id":"private-vault","name":"Private"},"category":"LOGIN"}'
          i=$((i + 1))
        done
        printf ']'
        """)
        // Generous hang-guard (matches the cancel test below), NOT an SLA: a 2s ceiling races the
        // 2500-item script + drain under CPU load and false-fails with .timedOut (reproduced 3/3).
        let lister = OnePasswordCLIItemLister(executableURL: scriptURL, timeout: .seconds(30))

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
        // Generous timeout on purpose: this test cancels manually (below), so the ProcessRunner
        // timeout must NOT be a competing terminator — a 2s ceiling races the child's first write
        // under load and lets the timeout (→ .failed) fire instead of the cancel (→ CancellationError).
        let lister = OnePasswordCLIItemLister(executableURL: scriptURL, timeout: .seconds(30))

        let task = Task {
            try await lister.listItems()
        }
        // Higher attempt budget so a slow process spawn under CI/load can't miss the file-write window.
        let started = await eventually(attempts: 200) {
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
        let terminated = await eventually(attempts: 200) {
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
        let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        let settings = MemoryResultTarget.systemSettings(settingsURL)
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

    @Test("mdfind spotlight search drops non-path lines merged from stderr")
    func mdfindSpotlightSearchDropsNonPathLines() async throws {
        let root = try temporaryDirectory()
        let script = root.appendingPathComponent("noisy-mdfind")
        // mdfind merges stderr into stdout (separateStderr: false); a warning line on an otherwise
        // successful run must not be mistaken for a result path.
        try createTextFile(at: script, contents: """
        #!/bin/sh
        echo '/Users/example/one.txt'
        echo '[UserQueryParser] note: ignoring malformed token'
        echo '/Users/example/two.txt'
        """)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let spotlight = MdfindSpotlightSearch(executableURL: script, timeout: .seconds(10))

        let results = try await spotlight.search(query: "anything", root: root)

        #expect(results.map(\.path) == ["/Users/example/one.txt", "/Users/example/two.txt"])
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
        let task = Task {
            try await spotlight.search(query: "anything", root: root)
        }

        try await Task.sleep(for: .milliseconds(100))
        let cancelledAt = Date()
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected mdfind cancellation")
        } catch is CancellationError {
        }
        // Returned promptly AFTER the cancel (not after the 3s script). Measured from the cancel, not
        // the task start, so a busy machine's scheduling latency before the cancel can't flake it; the
        // < 2s budget still discriminates a prompt terminate from waiting out the 3s script.
        #expect(Date().timeIntervalSince(cancelledAt) < 2)
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
        let descriptorMessage = "open descriptors after launch failures: "
            + "\(openDescriptorsAfter), before: \(openDescriptorsBefore)"
        #expect(returnedToBaseline, Comment(rawValue: descriptorMessage))
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
// swiftlint:enable file_length type_body_length
