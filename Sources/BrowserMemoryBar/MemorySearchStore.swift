import AppKit
import Foundation

// The central search coordinator — state, orchestration, paging, and presentation helpers all in one
// place; it sits a few lines over the 500 budget.
// swiftlint:disable file_length

@MainActor
final class MemorySearchStore: ObservableObject {
    enum Phase {
        case idle
        case loading
        case results
    }

    /// How the result list is ordered. `.relevance` keeps the providers' ranking; `.recent` sorts
    /// by each result's `sortDate` (file mtime / page visit), dateless results last.
    enum SortMode: CaseIterable {
        case relevance
        case recent

        var label: String {
            switch self {
            case .relevance: return "Most relevant"
            case .recent: return "Most recent"
            }
        }

        var systemImage: String {
            switch self {
            case .relevance: return "sparkles"
            case .recent: return "clock"
            }
        }

        var next: SortMode { self == .relevance ? .recent : .relevance }
    }

    @Published var phase: Phase = .idle
    @Published var inputText = ""
    @Published private(set) var baseQuery = ""
    @Published private(set) var refinements: [String] = []
    @Published private(set) var results: [MemoryResult] = []
    @Published private(set) var sortMode: SortMode = .relevance
    @Published private(set) var sourceStatuses: [MemorySearchSourceStatus] = []
    /// True while a search is actually executing (post-debounce / on Enter), independent of whether
    /// there are results on screen. Lets the UI signal a live re-search — spinner + dimmed stale rows
    /// — instead of looking frozen when you edit a query that already has results ("stale-while-
    /// revalidate"). Not set during the debounce wait, so it doesn't flash on every keystroke.
    @Published private(set) var isSearching = false
    @Published var selectedID: MemoryResult.ID?

    private var searchTask: Task<Void, Never>?
    private var allResults: [MemoryResult] = []
    private var currentPage = 0
    private let pageSize: Int
    private let resultFetchLimit: Int
    private let searchProvider: any MemorySearching
    private let resultOpener: any MemoryResultOpening
    private let diagnostics: RememBarDiagnostics
    /// How long typing settles before a live search fires. Injected so tests control timing; 180 ms is
    /// the launcher sweet spot (Algolia's proven default; well under the 300 ms degradation ceiling).
    private let searchDebounce: Duration
    /// Live typing needs at least this many characters before it searches, so a lone character can't
    /// fire a match-everything query. Enter (`submit()`) bypasses this — an explicit search is honored
    /// at any length.
    private static let minLiveQueryLength = 2

    init(
        searchProvider: any MemorySearching = CompositeMemorySearchProvider(),
        resultOpener: any MemoryResultOpening = WorkspaceMemoryResultOpener(),
        diagnostics: RememBarDiagnostics = .shared,
        pageSize: Int = 5,
        resultFetchLimit: Int = 25,
        searchDebounce: Duration = .milliseconds(180)
    ) {
        self.searchProvider = searchProvider
        self.resultOpener = resultOpener
        self.diagnostics = diagnostics
        self.pageSize = max(1, pageSize)
        self.resultFetchLimit = max(self.pageSize, resultFetchLimit)
        self.searchDebounce = searchDebounce
    }

    /// True once a search has completed for the current query but found nothing — a distinct state
    /// from `.loading` and `.idle`, so the panel can show a real "no results" message.
    var showsNoResults: Bool {
        phase == .results && results.isEmpty
    }

    var isActive: Bool {
        phase != .idle || !inputText.isEmpty || !baseQuery.isEmpty
    }

    var isLoading: Bool {
        phase == .loading
    }

    var canClearSearch: Bool {
        phase != .idle || !inputText.isEmpty || !baseQuery.isEmpty || !refinements.isEmpty || !results.isEmpty
    }

    var prompt: String {
        "Search files and history"
    }

    var phaseLabel: String {
        if phase == .loading {
            return "Searching"
        }
        return "Searched"
    }

    var contextValue: String {
        baseQuery
    }

    /// Show the "Searched X" line only once the field is edited away from the results' query — before
    /// that it would just duplicate the (now-persistent) field.
    var showsResultsQuery: Bool {
        !baseQuery.isEmpty && inputText.trimmingCharacters(in: .whitespacesAndNewlines) != baseQuery
    }

    var totalPages: Int {
        guard !allResults.isEmpty else { return 0 }
        return Int(ceil(Double(allResults.count) / Double(pageSize)))
    }

    var pageLabel: String {
        guard totalPages > 0 else { return "" }
        return "\(currentPage + 1) of \(totalPages)"
    }

    var canGoToPreviousPage: Bool {
        currentPage > 0
    }

    var canGoToNextPage: Bool {
        currentPage + 1 < totalPages
    }

    /// Explicit search (Enter / the search button): runs immediately, honoring any query length.
    func submit() {
        let query = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            diagnostics.record(RememBarDiagnosticEvent.searchSubmitIgnored, fields: ["reason": "empty"])
            return
        }
        dispatchSearch(query: query, immediate: true)
    }

    /// Live search: called as the field's text changes. Empty input returns to idle; a too-short query
    /// waits (Enter can still force it); otherwise it schedules a debounced search. Routes through the
    /// same single dispatch pipeline as `submit()` — there is no second search path.
    func inputChanged() {
        let query = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        // The single re-entrancy guard: only act when the EFFECTIVE query actually changed. `submit()`,
        // `retry()`, and `clearSearch()` all write `inputText` programmatically, which re-enters here
        // via the field's `onChange`; because each leaves `inputText` matching `baseQuery` (or both
        // empty), those echoes no-op instead of double-dispatching. Also absorbs whitespace-only churn.
        guard query != baseQuery else { return }
        guard !query.isEmpty else {
            clearSearch()
            return
        }
        guard query.count >= Self.minLiveQueryLength else {
            // Too short to search live: cancel any pending fire, never strand the loading skeleton with
            // no in-flight task, and abandon the search identity so returning to a longer query re-runs.
            searchTask?.cancel()
            isSearching = false
            if phase == .loading { phase = .idle }
            baseQuery = ""
            return
        }
        dispatchSearch(query: query, immediate: false)
    }

    /// The single search-dispatch authority. `immediate` fires now (Enter); otherwise the search is
    /// debounced by `searchDebounce`. Latest-wins is guaranteed by cancelling the prior task — the
    /// stale task bails in `finishSearch()` before committing. Results are NOT blanked here
    /// (stale-while-revalidate): the current results stay visible until the new response replaces them.
    private func dispatchSearch(query: String, immediate: Bool) {
        let previousPhase = phase
        let previousRefinementCount = refinements.count
        baseQuery = query
        refinements = []
        diagnostics.record(
            RememBarDiagnosticEvent.searchSubmit,
            fields: [
                "query": query,
                "queryLength": "\(query.count)",
                "isRefinement": "false",
                "refinementCount": "0",
                "previousRefinementCount": "\(previousRefinementCount)",
                "previousPhase": "\(previousPhase)",
                "submitPhase": "\(previousPhase)",
                "immediate": "\(immediate)"
            ]
        )

        searchTask?.cancel()
        // Only show the loading state when there's nothing to keep on screen (a cold search). During a
        // revalidate the existing rows stay put, so no skeleton flash between keystrokes.
        if results.isEmpty {
            phase = .loading
        }
        selectedID = nil

        let interval = immediate ? .zero : searchDebounce
        searchTask = Task { [weak self] in
            if interval > .zero {
                self?.recordSearchDebounceScheduled()
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else {
                    self?.recordSearchDebounceCancelled()
                    return
                }
                self?.recordSearchDebounceFired()
            }
            await self?.finishSearch()
        }
    }

    func clearSearch() {
        diagnostics.record(
            RememBarDiagnosticEvent.searchClear,
            fields: [
                "baseQuery": baseQuery,
                "refinementCount": "\(refinements.count)",
                "resultCount": "\(results.count)"
            ]
        )
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
        inputText = ""
        baseQuery = ""
        refinements = []
        allResults = []
        results = []
        sourceStatuses = []
        currentPage = 0
        selectedID = nil
        phase = .idle
    }

    func goToPreviousPage() {
        guard canGoToPreviousPage else { return }
        currentPage -= 1
        applyCurrentPage()
    }

    func goToNextPage() {
        guard canGoToNextPage else { return }
        currentPage += 1
        applyCurrentPage()
    }

    func select(_ result: MemoryResult) {
        diagnostics.record(RememBarDiagnosticEvent.resultSelect, fields: result.diagnosticFields)
        selectedID = result.id
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result.copyValue, forType: .string)
    }

    func open(_ result: MemoryResult) {
        diagnostics.record(RememBarDiagnosticEvent.resultOpenRequested, fields: result.diagnosticFields)
        resultOpener.open(result)
    }

    /// Acts on a problem source's offered remediation. Reuses the existing settings-URL constant,
    /// the `.systemSettings` open path, and `submit()` — no parallel machinery.
    func performRemediation(_ remediation: SourceRemediation) {
        switch remediation {
        case .grantFullDiskAccess:
            let target = MemoryResult(
                id: "remediation.fullDiskAccess",
                title: "Full Disk Access",
                detail: "Grant RememBar permission to read browser history",
                systemSettingsURL: FileSearchAccessIssue.fullDiskAccessSettingsURL
            )
            open(target)
        case .enablePasswordManagerCLI:
            // Not a macOS permission — 1Password is read via its `op` CLI, which needs the desktop
            // app's "Integrate with 1Password CLI" turned on (and an unlocked vault). Point at the docs.
            let target = MemoryResult(
                id: "remediation.passwordManagerCLI",
                title: "Enable 1Password CLI",
                detail: "How to let RememBar read 1Password item titles",
                systemSettingsURL: URL(string: "https://developer.1password.com/docs/cli/get-started/")!
            )
            open(target)
        case .retrySearch:
            retry()
        }
    }

    /// Re-runs the current query through the normal search path.
    func retry() {
        let query = baseQuery
        guard !query.isEmpty, phase != .loading else { return }
        inputText = query
        submit()
    }

    private func recordSearchDebounceScheduled() {
        diagnostics.record(RememBarDiagnosticEvent.searchDebounceScheduled, fields: ["baseQuery": baseQuery])
    }

    private func recordSearchDebounceFired() {
        diagnostics.record(RememBarDiagnosticEvent.searchDebounceFired, fields: ["baseQuery": baseQuery])
    }

    private func recordSearchDebounceCancelled() {
        diagnostics.record(
            RememBarDiagnosticEvent.searchDebounceCancelled,
            level: .warning,
            fields: ["baseQuery": baseQuery]
        )
    }

    private func finishSearch() async {
        // The search is now actually executing (past any debounce) — signal it so the UI can show a
        // live re-search even when stale results stay on screen. Left untouched in the cancelled path
        // below so a newer in-flight search keeps the signal; the committing search clears it.
        isSearching = true
        let provider = searchProvider
        let query = baseQuery
        let activeRefinements = refinements
        let limit = resultFetchLimit
        let startedAt = Date()
        diagnostics.record(
            RememBarDiagnosticEvent.searchStarted,
            fields: [
                "query": query,
                "refinementCount": "\(activeRefinements.count)",
                "limit": "\(limit)",
                "pageSize": "\(pageSize)"
            ]
        )

        let response = await provider.searchResponse(
            query: query,
            refinements: activeRefinements,
            limit: limit
        )
        guard !Task.isCancelled else {
            diagnostics.record(
                RememBarDiagnosticEvent.searchCancelledAfterProvider,
                level: .warning,
                fields: [
                    "query": query,
                    "refinementCount": "\(activeRefinements.count)",
                    "providerResultCount": "\(response.results.count)",
                    "sourceStatusCount": "\(response.sourceStatuses.count)"
                ]
            )
            return
        }

        allResults = response.results
        sourceStatuses = response.sourceStatuses
        currentPage = 0
        applyCurrentPage()
        phase = .results
        isSearching = false
        diagnostics.record(
            RememBarDiagnosticEvent.searchFinished,
            fields: searchFinishedFields(
                query: query,
                activeRefinements: activeRefinements,
                startedAt: startedAt
            )
        )
    }

    private func searchFinishedFields(
        query: String,
        activeRefinements: [String],
        startedAt: Date
    ) -> [String: String] {
        [
            "query": query,
            "refinementCount": "\(activeRefinements.count)",
            "resultCount": "\(results.count)",
            "allResultCount": "\(allResults.count)",
            "sourceStatusCount": "\(sourceStatuses.count)",
            "page": "\(currentPage + 1)",
            "totalPages": "\(totalPages)",
            "topResultIDs": results.prefix(5).map(\.id).joined(separator: ","),
            "durationMs": "\(Int(Date().timeIntervalSince(startedAt) * 1000))"
        ]
    }

    /// Results in the current sort order. `.relevance` preserves provider ranking; `.recent` sorts
    /// by `sortDate` descending — dateless results last, stable on ties.
    private var orderedResults: [MemoryResult] {
        switch sortMode {
        case .relevance:
            return allResults
        case .recent:
            return allResults.enumerated()
                .sorted { lhs, rhs in
                    let lhsDate = lhs.element.sortDate ?? .distantPast
                    let rhsDate = rhs.element.sortDate ?? .distantPast
                    return lhsDate == rhsDate ? lhs.offset < rhs.offset : lhsDate > rhsDate
                }
                .map(\.element)
        }
    }

    func setSortMode(_ mode: SortMode) {
        guard mode != sortMode else { return }
        sortMode = mode
        // Keep the current selection visible across the re-sort: page to where it now sits.
        if let selectedID, let index = orderedResults.firstIndex(where: { $0.id == selectedID }) {
            currentPage = index / pageSize
        } else {
            currentPage = 0
        }
        applyCurrentPage()
    }

    private func applyCurrentPage() {
        let ordered = orderedResults
        let start = currentPage * pageSize
        if start < ordered.count {
            results = Array(ordered.dropFirst(start).prefix(pageSize))
        } else {
            results = []
        }
        // Preserve the selection across re-sort / pagination; drop it only if the selected result
        // no longer exists at all (a fresh search clears it explicitly elsewhere).
        if let selectedID, !ordered.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
        }
    }
}

protocol MemorySearching: Sendable {
    func search(query: String, refinements: [String], limit: Int) async -> [MemoryResult]
    func searchResponse(query: String, refinements: [String], limit: Int) async -> MemorySearchResponse
}

extension MemorySearching {
    // `searchResponse` is the required primitive (no default), so a conformer that implements
    // neither method is a COMPILE error rather than a runtime infinite recursion. `search` is
    // derived from it — providers that only care about results never implement it.
    func search(query: String, refinements: [String], limit: Int) async -> [MemoryResult] {
        await searchResponse(query: query, refinements: refinements, limit: limit).results
    }
}

struct SampleMemorySearchProvider: MemorySearching, Sendable {
    func searchResponse(query: String, refinements: [String], limit: Int) async -> MemorySearchResponse {
        let ids = refinements.isEmpty ? MemoryResult.initialRanking : MemoryResult.refinedRanking
        let results = ids.prefix(limit).compactMap { id -> MemoryResult? in
            guard var result = MemoryResult.samples[id] else { return nil }
            if !refinements.isEmpty, let refinedDetail = result.refinedDetail {
                result.detail = refinedDetail
            }
            return result
        }
        return MemorySearchResponse(results: results)
    }
}

protocol BrowserOpening: Sendable {
    func open(_ url: URL, in browser: BrowserRef)
}

@MainActor
protocol MemoryResultOpening {
    func open(_ result: MemoryResult)
}

struct WorkspaceMemoryResultOpener: MemoryResultOpening {
    private let browserOpener: any BrowserOpening
    private let workspace: NSWorkspace
    private let diagnostics: RememBarDiagnostics

    init(
        browserOpener: (any BrowserOpening)? = nil,
        workspace: NSWorkspace = .shared,
        diagnostics: RememBarDiagnostics = .shared
    ) {
        self.browserOpener = browserOpener ?? WorkspaceBrowserOpener(diagnostics: diagnostics)
        self.workspace = workspace
        self.diagnostics = diagnostics
    }

    func open(_ result: MemoryResult) {
        switch result.target {
        case .web(let url, let browser):
            diagnostics.record(RememBarDiagnosticEvent.resultOpenWeb, fields: result.diagnosticFields)
            browserOpener.open(url, in: browser)
        case .file(let url):
            diagnostics.record(RememBarDiagnosticEvent.resultOpenFile, fields: result.diagnosticFields)
            workspace.activateFileViewerSelecting([url])
        case .systemSettings(let url):
            diagnostics.record(RememBarDiagnosticEvent.resultOpenSystemSettings, fields: result.diagnosticFields)
            workspace.open(url)
        case .externalApp(let target):
            guard target.canOpen else {
                var fields = result.diagnosticFields
                fields["reason"] = "unsupported_scheme"
                diagnostics.record(
                    RememBarDiagnosticEvent.resultOpenExternalAppRejected,
                    level: .warning,
                    fields: fields
                )
                return
            }
            diagnostics.record(RememBarDiagnosticEvent.resultOpenExternalApp, fields: result.diagnosticFields)
            workspace.open(target.url)
        }
    }
}

struct WorkspaceBrowserOpener: BrowserOpening {
    private let diagnostics: RememBarDiagnostics

    init(diagnostics: RememBarDiagnostics = .shared) {
        self.diagnostics = diagnostics
    }

    func open(_ url: URL, in browser: BrowserRef) {
        guard Self.canOpen(url) else {
            diagnostics.record(
                RememBarDiagnosticEvent.browserOpenRejected,
                level: .warning,
                fields: ["url": url.absoluteString, "browser": browser.displayName, "reason": "unsupported_scheme"]
            )
            return
        }

        let workspace = NSWorkspace.shared
        guard let appURL = Self.applicationURL(for: browser, workspace: workspace) else {
            diagnostics.record(
                RememBarDiagnosticEvent.browserOpenRejected,
                level: .warning,
                fields: ["url": url.absoluteString, "browser": browser.displayName, "reason": "browser_not_found"]
            )
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        diagnostics.record(
            RememBarDiagnosticEvent.browserOpenStarted,
            fields: ["url": url.absoluteString, "browser": browser.displayName, "app": appURL.path]
        )
        workspace.open([url], withApplicationAt: appURL, configuration: configuration)
    }

    static func canOpen(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    static func applicationURL(for browser: BrowserRef, workspace: NSWorkspace = .shared) -> URL? {
        if let path = browser.bundlePathHint {
            let url = URL(fileURLWithPath: path)
            let bundleID = Bundle(url: url)?.bundleIdentifier
            if browser.bundleIdentifier == nil || bundleID == browser.bundleIdentifier {
                return url
            }
        }

        return browser.bundleIdentifier.flatMap(workspace.urlForApplication(withBundleIdentifier:))
    }
}
