// One provider suite per file; splitting scatters related cases, so the file/type length limits are relaxed here.
// swiftlint:disable file_length type_body_length
import AppKit
@testable import BrowserMemoryBar
import Foundation
import SQLite3
import Testing

@Suite("Search Providers")
struct ProviderTests {

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
            fileURL: URL(fileURLWithPath: "/Users/x/Downloads/recovery-codes.txt"),
            displayPath: "Downloads/recovery-codes.txt",
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
                #expect(value.contains("recovery-codes.txt") == false,
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

    @Test("history ranker expands aliases per slot without inflating the AND-threshold")
    func historyAliasSlots() {
        func row(_ title: String, _ url: String) -> HistoryItem {
            HistoryItem(browser: .zen, profile: "Default", visitedAt: Date(timeIntervalSince1970: 1_800_000_000),
                        title: title, url: URL(string: url)!, sourcePath: "/tmp/zen")
        }
        let aliases = AliasGroups(groups: [["evan", "ecn"]])
        let ecnPage = row("ECN blog", "https://ecn.dev/blog")
        let resumePage = row("resume tips", "https://example.com/resume")
        let ecnResume = row("ECN resume", "https://ecn.dev/resume")

        // single term: "evan" finds the ECN page via the alias — and nothing without it
        let evanAliased = HistoryRanker.search(rows: [ecnPage], query: "evan", limit: 10, aliases: aliases)
        #expect(evanAliased.map(\.title) == ["ECN blog"])
        #expect(HistoryRanker.search(rows: [ecnPage], query: "evan", limit: 10).isEmpty)

        // two slots "evan resume": a page matching ONLY the evan-group (no resume) is rejected —
        // the alias must not inflate the count and produce a false positive.
        let evanResume = HistoryRanker.search(
            rows: [ecnPage, resumePage, ecnResume],
            query: "evan resume",
            limit: 10,
            aliases: aliases
        )
        #expect(evanResume.map(\.title) == ["ECN resume"])

        // Pinned: typing two members of the SAME family ("evan ecn") is OR-treated — a page with
        // just "ecn" satisfies both slots. Degenerate input, but intentional.
        let evanEcn = HistoryRanker.search(rows: [ecnPage], query: "evan ecn", limit: 10, aliases: aliases)
        #expect(evanEcn.map(\.title) == ["ECN blog"])
    }

    @Test("history source discovery classifies chromium firefox and safari")
    func historySourceDiscoveryClassifiesFamilies() throws {
        let root = try temporaryDirectory()
        let support = "Library/Application Support/"
        try createEmptyFile(at: root.appendingPathComponent("Library/Safari/History.db"))
        try createEmptyFile(at: root.appendingPathComponent(support + "Google/Chrome/Default/History"))
        try createEmptyFile(at: root.appendingPathComponent(support + "zen/Profiles/abc.default/places.sqlite"))

        let sources = HistorySource.discover(home: root)

        #expect(sources.contains { $0.family == .safari && $0.browser.displayName == "Safari" })
        #expect(sources.contains { $0.family == .chromium && $0.browser.displayName == "Chrome" })
        #expect(sources.contains { $0.family == .firefox && $0.browser.displayName == "Zen" })
    }

    @Test("history source discovery includes non-default chromium profiles")
    func historySourceDiscoveryIncludesChromiumProfiles() throws {
        let root = try temporaryDirectory()
        let support = "Library/Application Support/"
        try createEmptyFile(at: root.appendingPathComponent(support + "Google/Chrome/Profile 1/History"))
        try createEmptyFile(at: root.appendingPathComponent(support + "com.operasoftware.Opera/History"))

        let sources = HistorySource.discover(home: root)

        #expect(sources.contains { $0.family == .chromium && $0.browser == .chrome && $0.profile == "Profile 1" })
        #expect(sources.contains { source in
            source.family == .chromium && source.browser == .opera
                && source.profile == "com.operasoftware.Opera"
        })
    }

    @Test("history source discovery reports profile root enumeration failures")
    func historySourceDiscoveryReportsProfileRootEnumerationFailures() throws {
        let root = try temporaryDirectory()
        let support = "Library/Application Support/"
        try createEmptyFile(at: root.appendingPathComponent(support + "Google/Chrome/Default/History"))
        try createTextFile(
            at: root.appendingPathComponent(support + "Firefox/Profiles"),
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
        let base = "/users/me/library/application support/"
        let chromeTestingPath = base + "google/chrome for testing/default/history"
        #expect(BrowserRef.chromiumFamily(forPath: chromeTestingPath) == .chromeForTesting)
        #expect(BrowserRef.chromiumFamily(forPath: base + "arc/user data/profile 1/history") == .arc)
        #expect(BrowserRef.chromiumFamily(forPath: base + "bravesoftware/brave-browser/default/history") == .brave)
        #expect(BrowserRef.chromiumFamily(forPath: base + "microsoft edge/profile 2/history") == .edge)
        #expect(BrowserRef.chromiumFamily(forPath: base + "vivaldi/default/history") == .vivaldi)
        #expect(BrowserRef.chromiumFamily(forPath: base + "com.operasoftware.opera/history") == .opera)
        #expect(BrowserRef.chromiumFamily(forPath: base + "chromium/default/history") == .chromium)
        #expect(BrowserRef.firefoxFamily(forPath: base + "firefox/profiles/main/places.sqlite") == .firefox)
        #expect(BrowserRef.firefoxFamily(forPath: base + "zen/profiles/main/places.sqlite") == .zen)
        #expect(BrowserRef.firefoxFamily(forPath: base + "waterfox/profiles/main/places.sqlite") == .waterfox)
        #expect(BrowserRef.firefoxFamily(forPath: base + "librewolf/profiles/main/places.sqlite") == .libreWolf)
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
        #expect(events.contains { event in
            event.name == "spotlight.provider.started" && event.fields["query"]?.contains("alpha") == true
        })
        #expect(events.contains { event in
            event.name == "spotlight.provider.failed"
                && event.fields["error"]?.contains("forced spotlight failure") == true
        })
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
        #expect(events.contains { event in
            event.name == "history.provider.finished"
                && event.fields["rowCount"] == "0" && event.fields["resultCount"] == "0"
        })
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
}
// swiftlint:enable file_length type_body_length
