import AppKit
import Foundation

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
    @Published var selectedID: MemoryResult.ID?

    private var searchTask: Task<Void, Never>?
    private var allResults: [MemoryResult] = []
    private var currentPage = 0
    private let pageSize: Int
    private let resultFetchLimit: Int
    private let searchProvider: any MemorySearching
    private let resultOpener: any MemoryResultOpening
    private let diagnostics: RememBarDiagnostics

    init(
        searchProvider: any MemorySearching = CompositeMemorySearchProvider(),
        resultOpener: any MemoryResultOpening = WorkspaceMemoryResultOpener(),
        diagnostics: RememBarDiagnostics = .shared,
        pageSize: Int = 5,
        resultFetchLimit: Int = 25
    ) {
        self.searchProvider = searchProvider
        self.resultOpener = resultOpener
        self.diagnostics = diagnostics
        self.pageSize = max(1, pageSize)
        self.resultFetchLimit = max(self.pageSize, resultFetchLimit)
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

    func submit() {
        let query = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            diagnostics.record(RememBarDiagnosticEvent.searchSubmitIgnored, fields: ["reason": "empty"])
            return
        }
        guard phase != .loading else {
            diagnostics.record(RememBarDiagnosticEvent.searchSubmitIgnored, fields: ["reason": "loading", "query": query])
            return
        }

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
                "submitPhase": "\(previousPhase)"
            ]
        )

        searchTask?.cancel()
        inputText = ""
        phase = .loading
        allResults = []
        results = []
        sourceStatuses = []
        currentPage = 0
        selectedID = nil

        searchTask = Task { [weak self] in
            self?.recordSearchDebounceScheduled()
            try? await Task.sleep(for: .milliseconds(620))
            guard !Task.isCancelled else {
                self?.recordSearchDebounceCancelled()
                return
            }
            self?.recordSearchDebounceFired()
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
        diagnostics.record(RememBarDiagnosticEvent.searchDebounceCancelled, level: .warning, fields: ["baseQuery": baseQuery])
    }

    private func finishSearch() async {
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
        diagnostics.record(
            RememBarDiagnosticEvent.searchFinished,
            fields: [
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
        )
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
                    let l = lhs.element.sortDate ?? .distantPast
                    let r = rhs.element.sortDate ?? .distantPast
                    return l == r ? lhs.offset < rhs.offset : l > r
                }
                .map(\.element)
        }
    }

    func setSortMode(_ mode: SortMode) {
        guard mode != sortMode else { return }
        sortMode = mode
        currentPage = 0
        applyCurrentPage()
    }

    private func applyCurrentPage() {
        let ordered = orderedResults
        let start = currentPage * pageSize
        guard start < ordered.count else {
            results = []
            return
        }
        results = Array(ordered.dropFirst(start).prefix(pageSize))
        selectedID = nil
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

struct MemoryResult: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    var detail: String
    let refinedDetail: String?
    let thumbnail: MemoryResultThumbnail?
    let target: MemoryResultTarget
    let rank: Int
    /// When this result was last touched (page visit / file mtime). nil for dateless results
    /// (settings, app actions). Drives the "Most recent" sort.
    let sortDate: Date?

    init(
        id: String,
        title: String,
        detail: String,
        refinedDetail: String?,
        url: URL,
        thumbnailURL: URL?,
        browser: BrowserRef,
        rank: Int = 0,
        visitedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.refinedDetail = refinedDetail
        self.thumbnail = thumbnailURL.map(MemoryResultThumbnail.remoteImage)
        self.target = .web(url: url, browser: browser)
        self.rank = rank
        self.sortDate = visitedAt
    }

    init(fileURL: URL, displayPath: String, modifiedAt: Date, rank: Int) {
        self.id = "file|\(fileURL.path)"
        self.title = fileURL.lastPathComponent
        self.detail = "File · \(modifiedAt.formatted(.dateTime.month().day())) · \(displayPath)"
        self.refinedDetail = nil
        // Never generate a content preview for secret-bearing files: Quick Look would rasterize
        // their contents (e.g. recovery codes) into an image and cache it on disk. Fall back to
        // the extension tile instead. SensitivePathPolicy is the single authority for this rule.
        self.thumbnail = SensitivePathPolicy.isSensitive(fileURL) ? nil : .filePreview(fileURL)
        self.target = .file(fileURL)
        self.rank = rank
        self.sortDate = modifiedAt
    }

    init(id: String, title: String, detail: String, systemSettingsURL: URL, rank: Int = 0) {
        self.id = id
        self.title = title
        self.detail = detail
        self.refinedDetail = nil
        self.thumbnail = nil
        self.target = .systemSettings(systemSettingsURL)
        self.rank = rank
        self.sortDate = nil
    }

    init(id: String, title: String, detail: String, externalApp: ExternalAppTarget, rank: Int = 0) {
        self.id = id
        self.title = title
        self.detail = detail
        self.refinedDetail = nil
        self.thumbnail = nil
        self.target = .externalApp(externalApp)
        self.rank = rank
        self.sortDate = nil
    }

    var url: URL {
        target.url
    }

    var browser: BrowserRef? {
        target.browser
    }

    var copyValue: String {
        target.copyValue
    }

    var thumbnailURL: URL? {
        switch thumbnail {
        case .remoteImage(let url):
            return url
        case .filePreview, nil:
            return nil
        }
    }

    var kind: MemoryResultKind {
        MemoryResultKind(target: target)
    }

    var diagnosticFields: [String: String] {
        // For a file result the title IS the bare filename leaf, so redact it like the other
        // path-bearing fields. Web/page titles aren't paths and are left intact.
        let safeTitle = kind == .file ? SensitivePathPolicy.redactingSensitivePaths(in: title) : title
        var fields = [
            "id": id,
            "title": safeTitle,
            "detail": detail,
            "rank": "\(rank)",
            "kind": "\(kind)",
            "target": target.copyValue
        ]
        if let browser {
            fields["browser"] = browser.displayName
        }
        return fields
    }

    static let initialRanking = ["workflow", "claude-design", "codex-prototypes", "landing-pages", "faster-claude"]
    static let refinedRanking = ["workflow", "claude-design", "landing-pages", "codex-prototypes", "faster-claude"]

    // Generic placeholder data for previews/tests — not real browsing history. The fixed video
    // ids below are synthetic (they do not resolve to real videos).
    static let samples: [String: MemoryResult] = [
        "workflow": MemoryResult(
            id: "workflow",
            title: "Sample Workflow Video",
            detail: "Browser · recently · sample, demo",
            refinedDetail: "Best match · sample transcript keywords",
            url: URL(string: "https://www.youtube.com/watch?v=sample00001")!,
            thumbnailURL: URL(string: "https://img.youtube.com/vi/sample00001/hqdefault.jpg")!,
            browser: .chrome
        ),
        "claude-design": MemoryResult(
            id: "claude-design",
            title: "Sample Design Video",
            detail: "Browser · recently · sample, design",
            refinedDetail: "Related · sample design keywords",
            url: URL(string: "https://www.youtube.com/watch?v=sample00002")!,
            thumbnailURL: URL(string: "https://img.youtube.com/vi/sample00002/hqdefault.jpg")!,
            browser: .chrome
        ),
        "codex-prototypes": MemoryResult(
            id: "codex-prototypes",
            title: "Sample Prototyping Video",
            detail: "Browser · recently · sample, prototypes",
            refinedDetail: "Related · sample prototype keywords",
            url: URL(string: "https://www.youtube.com/watch?v=sample00003")!,
            thumbnailURL: URL(string: "https://img.youtube.com/vi/sample00003/hqdefault.jpg")!,
            browser: .chrome
        ),
        "landing-pages": MemoryResult(
            id: "landing-pages",
            title: "Sample Landing Page Video",
            detail: "Browser · recently · sample, landing pages",
            refinedDetail: "Related · sample landing page keywords",
            url: URL(string: "https://www.youtube.com/watch?v=sample00004")!,
            thumbnailURL: URL(string: "https://img.youtube.com/vi/sample00004/hqdefault.jpg")!,
            browser: .chrome
        ),
        "faster-claude": MemoryResult(
            id: "faster-claude",
            title: "Sample Productivity Video",
            detail: "Browser · recently · sample, productivity",
            refinedDetail: "Related · sample productivity keywords",
            url: URL(string: "https://www.youtube.com/watch?v=sample00005")!,
            thumbnailURL: URL(string: "https://img.youtube.com/vi/sample00005/hqdefault.jpg")!,
            browser: .chrome
        )
    ]
}

enum MemoryResultThumbnail: Equatable, Sendable {
    case remoteImage(URL)
    case filePreview(URL)
}

enum MemoryResultKind: Equatable, Sendable {
    case file
    case web
    case systemSettings
    case externalApp
    case youtubeVideo(id: String)
    case youtubeShort(id: String)
    case youtubeSearch(query: String)
    case youtubeChannel(label: String)
    case youtubePlaylist
    case youtubeHome

    init(target: MemoryResultTarget) {
        switch target {
        case .file:
            self = .file
        case .systemSettings:
            self = .systemSettings
        case .externalApp:
            self = .externalApp
        case .web(let url, _):
            self = MemoryResultKind(historyKind: HistoryResultKind(url: url))
        }
    }

    private init(historyKind: HistoryResultKind) {
        switch historyKind {
        case .web:
            self = .web
        case .youtubeVideo(let id):
            self = .youtubeVideo(id: id)
        case .youtubeShort(let id):
            self = .youtubeShort(id: id)
        case .youtubeSearch(let query):
            self = .youtubeSearch(query: query)
        case .youtubeChannel(let label):
            self = .youtubeChannel(label: label)
        case .youtubePlaylist:
            self = .youtubePlaylist
        case .youtubeHome:
            self = .youtubeHome
        }
    }
}

enum MemoryResultTarget: Equatable, Sendable {
    case web(url: URL, browser: BrowserRef)
    case file(URL)
    case systemSettings(URL)
    case externalApp(ExternalAppTarget)

    var url: URL {
        switch self {
        case .web(let url, _), .file(let url), .systemSettings(let url):
            return url
        case .externalApp(let target):
            return target.url
        }
    }

    var browser: BrowserRef? {
        switch self {
        case .web(_, let browser):
            return browser
        case .file, .systemSettings, .externalApp:
            return nil
        }
    }

    var copyValue: String {
        switch self {
        case .web(let url, _):
            return url.absoluteString
        case .file(let url):
            return url.path
        case .systemSettings(let url):
            return url.absoluteString
        case .externalApp(let target):
            return target.url.absoluteString
        }
    }

    var actionLabel: String {
        switch self {
        case .web:
            return "Open"
        case .file:
            return "Show in Finder"
        case .systemSettings:
            return "Open Settings"
        case .externalApp(let target):
            return target.actionLabel
        }
    }

}

struct ExternalAppTarget: Equatable, Sendable {
    let url: URL
    let actionLabel: String
    private let allowedScheme: String

    private init?(url: URL, actionLabel: String, allowedScheme: String) {
        guard url.scheme?.lowercased() == allowedScheme else { return nil }
        self.url = url
        self.actionLabel = actionLabel
        self.allowedScheme = allowedScheme
    }

    static func onePassword(
        url: URL = URL(string: "onepassword://")!,
        actionLabel: String = "Open 1Password"
    ) -> ExternalAppTarget? {
        ExternalAppTarget(url: url, actionLabel: actionLabel, allowedScheme: "onepassword")
    }

    var canOpen: Bool {
        url.scheme?.lowercased() == allowedScheme
    }
}

enum HistoryResultKind: Equatable, Sendable {
    case web
    case youtubeVideo(id: String)
    case youtubeShort(id: String)
    case youtubeSearch(query: String)
    case youtubeChannel(label: String)
    case youtubePlaylist
    case youtubeHome

    init(url: URL) {
        guard url.isYouTubeURL else {
            self = .web
            return
        }

        if url.normalizedHost == "youtu.be", let id = url.pathComponents.dropFirst().first {
            self = .youtubeVideo(id: id)
            return
        }

        if url.path == "/watch",
           let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "v" })?
            .value {
            self = .youtubeVideo(id: id)
            return
        }

        if url.pathComponents.count >= 3, url.pathComponents[1] == "shorts" {
            self = .youtubeShort(id: url.pathComponents[2])
            return
        }

        if url.path == "/results" {
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "search_query" })?
                .value?
                .replacingOccurrences(of: "+", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            self = .youtubeSearch(query: query?.isEmpty == false ? query! : "Search")
            return
        }

        if url.path == "/playlist" {
            self = .youtubePlaylist
            return
        }

        if let firstPath = url.pathComponents.dropFirst().first,
           firstPath.hasPrefix("@") || firstPath == "channel" || firstPath == "c" || firstPath == "user" {
            self = .youtubeChannel(label: firstPath.hasPrefix("@") ? firstPath : "Channel")
            return
        }

        self = url.path == "/" || url.path.isEmpty ? .youtubeHome : .web
    }

    var videoID: String? {
        switch self {
        case .youtubeVideo(let id), .youtubeShort(let id):
            return id
        case .web, .youtubeSearch, .youtubeChannel, .youtubePlaylist, .youtubeHome:
            return nil
        }
    }
}

struct BrowserRef: Equatable, Sendable {
    let displayName: String
    let bundleIdentifier: String?
    let bundlePathHint: String?

    static let chrome = BrowserRef(displayName: "Chrome", bundleIdentifier: "com.google.Chrome", bundlePathHint: nil)
    static let chromeForTesting = BrowserRef(displayName: "Chrome for Testing", bundleIdentifier: "com.google.chrome.for.testing", bundlePathHint: "/Applications/Google Chrome for Testing.app")
    static let safari = BrowserRef(displayName: "Safari", bundleIdentifier: "com.apple.Safari", bundlePathHint: nil)
    static let arc = BrowserRef(displayName: "Arc", bundleIdentifier: "company.thebrowser.Browser", bundlePathHint: "/Applications/Arc.app")
    static let brave = BrowserRef(displayName: "Brave", bundleIdentifier: "com.brave.Browser", bundlePathHint: "/Applications/Brave Browser.app")
    static let chromium = BrowserRef(displayName: "Chromium", bundleIdentifier: "org.chromium.Chromium", bundlePathHint: "/Applications/Chromium.app")
    static let edge = BrowserRef(displayName: "Microsoft Edge", bundleIdentifier: "com.microsoft.edgemac", bundlePathHint: "/Applications/Microsoft Edge.app")
    static let firefox = BrowserRef(displayName: "Firefox", bundleIdentifier: "org.mozilla.firefox", bundlePathHint: "/Applications/Firefox.app")
    static let libreWolf = BrowserRef(displayName: "LibreWolf", bundleIdentifier: nil, bundlePathHint: "/Applications/LibreWolf.app")
    static let opera = BrowserRef(displayName: "Opera", bundleIdentifier: "com.operasoftware.Opera", bundlePathHint: "/Applications/Opera.app")
    static let vivaldi = BrowserRef(displayName: "Vivaldi", bundleIdentifier: "com.vivaldi.Vivaldi", bundlePathHint: "/Applications/Vivaldi.app")
    static let waterfox = BrowserRef(displayName: "Waterfox", bundleIdentifier: nil, bundlePathHint: "/Applications/Waterfox.app")
    static let zen = BrowserRef(
        displayName: "Zen",
        bundleIdentifier: "app.zen-browser.zen",
        bundlePathHint: "/Applications/Zen.app"
    )

    static func chromiumFamily(forPath path: String) -> BrowserRef {
        if path.contains("/arc/") { return .arc }
        if path.contains("/bravesoftware/") || path.contains("/brave-browser/") { return .brave }
        if path.contains("/microsoft edge/") { return .edge }
        if path.contains("/com.operasoftware.opera/") { return .opera }
        if path.contains("/vivaldi/") { return .vivaldi }
        if path.contains("/chromium/") { return .chromium }
        if path.contains("/chrome for testing/") { return .chromeForTesting }
        return .chrome
    }

    static func firefoxFamily(forPath path: String) -> BrowserRef {
        if path.contains("/zen/") { return .zen }
        if path.contains("/waterfox/") { return .waterfox }
        if path.contains("/librewolf/") { return .libreWolf }
        return .firefox
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
                diagnostics.record(RememBarDiagnosticEvent.resultOpenExternalAppRejected, level: .warning, fields: fields)
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
