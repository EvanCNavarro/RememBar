import Foundation
import SQLite3

struct LocalHistorySearchProvider: MemorySearching, Sendable {
    private let home: URL
    private let window: HistorySearchWindow
    private let diagnostics: RememBarDiagnostics

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        window: HistorySearchWindow = .default,
        diagnostics: RememBarDiagnostics = .shared
    ) {
        self.home = home
        self.window = window
        self.diagnostics = diagnostics
    }

    init(home: URL, since: Date?, diagnostics: RememBarDiagnostics = .shared) {
        self.init(home: home, window: since.map(HistorySearchWindow.since) ?? .unbounded, diagnostics: diagnostics)
    }

    func searchResponse(query: String, refinements: [String], limit: Int) async -> MemorySearchResponse {
        let startedAt = Date()
        diagnostics.record(
            RememBarDiagnosticEvent.historyProviderStarted,
            fields: [
                "query": query,
                "refinementCount": "\(refinements.count)",
                "limit": "\(limit)",
                "home": home.path
            ]
        )
        let report = readReport()
        let results = HistoryRanker.searchRanked(rows: report.rows, query: query, refinements: refinements, limit: limit)
            .map { MemoryResult(historyItem: $0.item, rank: $0.score) }
        let sourceStatuses = report.sourceStatuses
        diagnostics.record(
            RememBarDiagnosticEvent.historyProviderFinished,
            fields: [
                "query": query,
                "rowCount": "\(report.rows.count)",
                "resultCount": "\(results.count)",
                "sourceCount": "\(report.sourceReads.count)",
                "sourceStatusCount": "\(sourceStatuses.count)",
                "discoveryIssueCount": "\(report.discoveryIssues.count)",
                "durationMs": "\(Int(Date().timeIntervalSince(startedAt) * 1000))"
            ]
        )
        return MemorySearchResponse(results: results, sourceStatuses: sourceStatuses)
    }

    func readReport(now: Date = Date()) -> HistoryReadReport {
        let since = window.since(now: now)
        diagnostics.record(
            RememBarDiagnosticEvent.historyReadStarted,
            fields: [
                "home": home.path,
                "since": since.map { "\($0.timeIntervalSince1970)" } ?? "unbounded"
            ]
        )
        let discoveryReport = HistorySource.discoverReport(home: home)
        diagnostics.record(
            RememBarDiagnosticEvent.historyDiscoveryFinished,
            fields: [
                "home": home.path,
                "sourceCount": "\(discoveryReport.sources.count)",
                "issueCount": "\(discoveryReport.issues.count)"
            ]
        )
        let sourceReads = discoveryReport.sources.map { source in
            let sourceFields = [
                "browser": source.browser.displayName,
                "profile": source.profile,
                "family": source.family.rawValue,
                "path": source.url.path
            ]
            diagnostics.record(RememBarDiagnosticEvent.historySourceReadStarted, fields: sourceFields)
            do {
                let rows = try HistoryDatabaseReader(source: source, since: since).readRows()
                var fields = sourceFields
                fields["rowCount"] = "\(rows.count)"
                diagnostics.record(
                    RememBarDiagnosticEvent.historySourceReadFinished,
                    fields: fields
                )
                return HistorySourceRead(
                    source: source,
                    result: .success(rows)
                )
            } catch {
                var fields = sourceFields
                fields["error"] = HistoryReadReport.describe(error)
                diagnostics.record(
                    RememBarDiagnosticEvent.historySourceReadFailed,
                    level: .error,
                    fields: fields
                )
                return HistorySourceRead(
                    source: source,
                    result: .failure(HistoryReadReport.describe(error))
                )
            }
        }
        return HistoryReadReport(sourceReads: sourceReads, discoveryIssues: discoveryReport.issues)
    }
}

enum HistorySearchWindow: Equatable, Sendable {
    case recent(days: Int)
    case since(Date)
    case unbounded

    static let defaultDays = 31
    static let `default` = HistorySearchWindow.recent(days: defaultDays)

    func since(now: Date = Date()) -> Date? {
        switch self {
        case .recent(let days):
            return now.addingTimeInterval(-TimeInterval(days * 24 * 60 * 60))
        case .since(let date):
            return date
        case .unbounded:
            return nil
        }
    }
}

struct HistoryReadReport: Equatable, Sendable {
    let sourceReads: [HistorySourceRead]
    let discoveryIssues: [HistoryDiscoveryIssue]

    var rows: [HistoryItem] {
        sourceReads.flatMap(\.rows)
    }

    var sourceStatuses: [MemorySearchSourceStatus] {
        if sourceReads.isEmpty && discoveryIssues.isEmpty {
            return [
                MemorySearchSourceStatus(
                    id: "history",
                    sourceName: "Browser History",
                    state: .unavailable,
                    detail: "No browser history databases found"
                )
            ]
        }
        return sourceReads.map(\.sourceStatus) + discoveryIssues.map(\.sourceStatus)
    }

    static func describe(_ error: Error) -> String {
        if let sqliteError = error as? SQLiteError {
            return sqliteError.description
        }
        return String(describing: error)
    }
}

struct HistorySourceRead: Equatable, Sendable {
    enum Result: Equatable, Sendable {
        case success([HistoryItem])
        case failure(String)
    }

    let source: HistorySource
    let result: Result

    var rows: [HistoryItem] {
        switch result {
        case .success(let rows):
            return rows
        case .failure:
            return []
        }
    }

    var errorDescription: String? {
        switch result {
        case .success:
            return nil
        case .failure(let description):
            return description
        }
    }

    var sourceStatus: MemorySearchSourceStatus {
        switch result {
        case .success(let rows):
            return MemorySearchSourceStatus(
                id: "history.\(source.idComponent)",
                sourceName: source.displayName,
                state: .searched,
                detail: "\(rows.count) visits"
            )
        case .failure(let description):
            return MemorySearchSourceStatus(
                id: "history.\(source.idComponent)",
                sourceName: source.displayName,
                state: Self.isPermissionFailure(description) ? .blocked : .failed,
                detail: Self.isPermissionFailure(description) ? "Permission required" : "Could not read this source"
            )
        }
    }

    private static func isPermissionFailure(_ description: String) -> Bool {
        let lower = description.lowercased()
        return lower.contains("authorization denied") ||
            lower.contains("operation not permitted") ||
            lower.contains("permission denied")
    }
}

struct HistoryDiscoveryReport: Equatable, Sendable {
    let sources: [HistorySource]
    let issues: [HistoryDiscoveryIssue]
}

struct HistoryDiscoveryIssue: Equatable, Sendable {
    let root: URL
    let errorDescription: String

    var sourceStatus: MemorySearchSourceStatus {
        MemorySearchSourceStatus(
            id: "history.discovery.\(Self.idComponent(root.path))",
            sourceName: root.lastPathComponent,
            state: .unavailable,
            detail: "Could not inspect source location"
        )
    }

    private static func idComponent(_ value: String) -> String {
        value
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }
}

struct HistoryItem: Equatable, Sendable {
    let browser: BrowserRef
    let profile: String
    let visitedAt: Date
    let title: String
    let url: URL
    let sourcePath: String
}

struct HistorySource: Equatable, Sendable {
    enum Family: String, Sendable {
        case chromium
        case firefox
        case safari
    }

    let browser: BrowserRef
    let profile: String
    let family: Family
    let url: URL

    var displayName: String {
        profile == "Default" ? browser.displayName : "\(browser.displayName) \(profile)"
    }

    var idComponent: String {
        "\(browser.displayName).\(profile)"
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }

    static func discover(home: URL, fileManager: FileManager = .default) -> [HistorySource] {
        discoverReport(home: home, fileManager: fileManager).sources
    }

    static func discoverReport(home: URL, fileManager: FileManager = .default) -> HistoryDiscoveryReport {
        let urlReport = expectedHistoryURLReport(home: home, fileManager: fileManager)
        let sources = urlReport.urls
            .filter { fileManager.fileExists(atPath: $0.path) }
            .compactMap(classify)
            .uniqueByPath()
        return HistoryDiscoveryReport(sources: sources, issues: urlReport.issues)
    }

    static func classify(_ url: URL) -> HistorySource? {
        let path = url.path
        let lower = path.lowercased()
        let filename = url.lastPathComponent

        if filename == "History.db" || lower.contains("/safari/") {
            return HistorySource(browser: .safari, profile: "Default", family: .safari, url: url)
        }

        if filename == "places.sqlite" {
            return HistorySource(
                browser: BrowserRef.firefoxFamily(forPath: lower),
                profile: url.deletingLastPathComponent().lastPathComponent,
                family: .firefox,
                url: url
            )
        }

        if filename == "History" {
            return HistorySource(
                browser: BrowserRef.chromiumFamily(forPath: lower),
                profile: url.deletingLastPathComponent().lastPathComponent,
                family: .chromium,
                url: url
            )
        }

        return nil
    }

    private static func expectedHistoryURLReport(home: URL, fileManager: FileManager) -> HistoryURLDiscoveryReport {
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        var urls = [
            home.appendingPathComponent("Library/Safari/History.db")
        ]
        var issues: [HistoryDiscoveryIssue] = []

        for root in [
            support.appendingPathComponent("Google/Chrome", isDirectory: true),
            support.appendingPathComponent("Google/Chrome for Testing", isDirectory: true),
            support.appendingPathComponent("Arc/User Data", isDirectory: true),
            support.appendingPathComponent("BraveSoftware/Brave-Browser", isDirectory: true),
            support.appendingPathComponent("Microsoft Edge", isDirectory: true),
            support.appendingPathComponent("com.operasoftware.Opera", isDirectory: true),
            support.appendingPathComponent("Vivaldi", isDirectory: true),
            support.appendingPathComponent("Chromium", isDirectory: true)
        ] {
            let report = chromiumHistoryURLReport(root: root, fileManager: fileManager)
            urls.append(contentsOf: report.urls)
            issues.append(contentsOf: report.issues)
        }

        for root in [
            support.appendingPathComponent("Firefox/Profiles", isDirectory: true),
            support.appendingPathComponent("zen/Profiles", isDirectory: true),
            support.appendingPathComponent("Waterfox/Profiles", isDirectory: true),
            support.appendingPathComponent("LibreWolf/Profiles", isDirectory: true)
        ] where fileManager.fileExists(atPath: root.path) {
            do {
                let profiles = try fileManager.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )
                urls.append(contentsOf: profiles.map { $0.appendingPathComponent("places.sqlite") })
            } catch {
                issues.append(HistoryDiscoveryIssue(root: root, errorDescription: describe(error)))
            }
        }

        return HistoryURLDiscoveryReport(urls: urls, issues: issues)
    }

    private static func chromiumHistoryURLReport(root: URL, fileManager: FileManager) -> HistoryURLDiscoveryReport {
        guard fileManager.fileExists(atPath: root.path) else {
            return HistoryURLDiscoveryReport(urls: [], issues: [])
        }

        var urls = [root.appendingPathComponent("History")]
        do {
            let children = try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            urls.append(contentsOf: children.compactMap { child in
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey])
                guard values?.isDirectory == true else { return nil }
                return child.appendingPathComponent("History")
            })
            return HistoryURLDiscoveryReport(urls: urls, issues: [])
        } catch {
            return HistoryURLDiscoveryReport(
                urls: urls,
                issues: [HistoryDiscoveryIssue(root: root, errorDescription: describe(error))]
            )
        }
    }

    private static func describe(_ error: Error) -> String {
        String(describing: error)
    }
}

private struct HistoryURLDiscoveryReport {
    let urls: [URL]
    let issues: [HistoryDiscoveryIssue]
}

private struct HistoryDatabaseReader {
    private static let rowLimit = 50_000

    let source: HistorySource
    let since: Date?

    func readRows() throws -> [HistoryItem] {
        try SQLiteSnapshot.withSnapshot(of: source.url, fileManager: .default) { snapshot in
            let database = try SQLiteDatabase(url: snapshot)
            defer { database.close() }
            return try queryRows(database)
        }
    }

    private func queryRows(_ database: SQLiteDatabase) throws -> [HistoryItem] {
        let sql: String
        let visitedAt: (SQLiteStatement) -> Date

        switch source.family {
        case .chromium:
            let sinceClause = since.map { "WHERE v.visit_time >= \(HistoryDate.chromiumTimestamp($0))" } ?? ""
            sql = """
                SELECT v.visit_time, COALESCE(u.title, ''), u.url
                FROM visits v JOIN urls u ON u.id = v.url
                \(sinceClause)
                ORDER BY v.visit_time DESC
                LIMIT \(Self.rowLimit)
                """
            visitedAt = { HistoryDate.chromium($0.int64(at: 0)) }
        case .firefox:
            let sinceClause = since.map { "WHERE v.visit_date >= \(HistoryDate.firefoxTimestamp($0))" } ?? ""
            sql = """
                SELECT v.visit_date, COALESCE(p.title, ''), p.url
                FROM moz_historyvisits v JOIN moz_places p ON p.id = v.place_id
                \(sinceClause)
                ORDER BY v.visit_date DESC
                LIMIT \(Self.rowLimit)
                """
            visitedAt = { HistoryDate.firefox($0.int64(at: 0)) }
        case .safari:
            let sinceClause = since.map { "WHERE v.visit_time >= \(HistoryDate.safariTimestamp($0))" } ?? ""
            sql = """
                SELECT v.visit_time, COALESCE(v.title, ''), i.url
                FROM history_visits v JOIN history_items i ON i.id = v.history_item
                \(sinceClause)
                ORDER BY v.visit_time DESC
                LIMIT \(Self.rowLimit)
                """
            visitedAt = { HistoryDate.safari($0.double(at: 0)) }
        }

        return try database.query(sql) { statement in
            guard let url = URL(string: statement.text(at: 2)), WorkspaceBrowserOpener.canOpen(url) else {
                return nil
            }
            let visitedAtDate = visitedAt(statement)
            if let since, visitedAtDate < since {
                return nil
            }
            return HistoryItem(
                browser: source.browser,
                profile: source.profile,
                visitedAt: visitedAtDate,
                title: statement.text(at: 1),
                url: url,
                sourcePath: source.url.path
            )
        }
    }
}

enum HistoryDate {
    static func chromium(_ value: Int64) -> Date {
        Date(timeInterval: TimeInterval(value) / 1_000_000, since: Date(timeIntervalSince1970: -11_644_473_600))
    }

    static func chromiumTimestamp(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince(Date(timeIntervalSince1970: -11_644_473_600)) * 1_000_000)
    }

    static func firefox(_ value: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(value) / 1_000_000)
    }

    static func firefoxTimestamp(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1_000_000)
    }

    static func safari(_ value: Double) -> Date {
        Date(timeInterval: value, since: Date(timeIntervalSinceReferenceDate: 0))
    }

    static func safariTimestamp(_ date: Date) -> Double {
        date.timeIntervalSinceReferenceDate
    }
}

enum HistoryRanker {
    static func search(rows: [HistoryItem], query: String, refinements: [String] = [], limit: Int) -> [HistoryItem] {
        searchRanked(rows: rows, query: query, refinements: refinements, limit: limit)
            .map(\.item)
    }

    static func searchRanked(rows: [HistoryItem], query: String, refinements: [String] = [], limit: Int) -> [RankedHistoryItem] {
        let terms = tokenize(query)
        let refinementTerms = tokenize(refinements.joined(separator: " "))
        let wantsYouTube = (terms + refinementTerms).contains { $0 == "youtube" || $0 == "youtu" }
        let contentTerms = terms.filter { $0 != "youtube" && $0 != "youtu" }
        let contentRefinementTerms = refinementTerms.filter { $0 != "youtube" && $0 != "youtu" }
        return rows
            .compactMap { row -> (HistoryItem, Int)? in
                let score = score(
                    row: row,
                    terms: contentTerms,
                    refinementTerms: contentRefinementTerms,
                    query: query,
                    wantsYouTube: wantsYouTube
                )
                return score > 0 ? (row, score) : nil
            }
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 {
                    return lhs.0.visitedAt > rhs.0.visitedAt
                }
                return lhs.1 > rhs.1
            }
            .prefix(limit)
            .map { RankedHistoryItem(item: $0.0, score: $0.1) }
    }

    static func tokenize(_ text: String) -> [String] {
        MemorySearchTokenizer.tokenize(text)
    }

    private static func score(
        row: HistoryItem,
        terms: [String],
        refinementTerms: [String],
        query: String,
        wantsYouTube: Bool
    ) -> Int {
        if wantsYouTube, !isYouTube(row.url) {
            return 0
        }
        guard !terms.isEmpty else {
            return wantsYouTube ? 30 + youtubeVideoScore(row.url) : 1
        }
        let urlText = row.url.absoluteString.lowercased()
        let titleTerms = Set(tokenize(row.title))
        let urlTerms = Set(tokenize(urlText))
        let contextTerms = Set(tokenize("\(row.browser.displayName) \(row.profile)"))
        let rowTerms = titleTerms.union(urlTerms).union(contextTerms)
        var score = 0
        var matched = 0

        for term in terms where rowTerms.contains(term) {
            matched += 1
            if titleTerms.contains(term) {
                score += 70
            } else if urlTerms.contains(term) {
                score += 55
            } else {
                score += 35
            }
        }

        guard matched >= requiredContentMatches(for: terms.count) else { return 0 }
        if wantsYouTube {
            score += 30
            score += youtubeVideoScore(row.url)
        }
        for term in refinementTerms where rowTerms.contains(term) {
            score += urlTerms.contains(term) ? 20 : 15
        }
        score += min(20, query.count)
        return score
    }

    private static func requiredContentMatches(for termCount: Int) -> Int {
        guard termCount > 3 else { return termCount }
        return max(2, Int(ceil(Double(termCount) * 0.6)))
    }

    private static func isYouTube(_ url: URL) -> Bool {
        url.isYouTubeURL
    }

    private static func youtubeVideoScore(_ url: URL) -> Int {
        let host = url.normalizedHost
        if host == "youtu.be" {
            return 55
        }
        guard host == "youtube.com" || host.hasSuffix(".youtube.com") else { return 0 }
        if url.path == "/watch" {
            return 55
        }
        if url.path.hasPrefix("/shorts/") {
            return 35
        }
        return 0
    }
}

struct RankedHistoryItem: Equatable, Sendable {
    let item: HistoryItem
    let score: Int
}

private enum SQLiteSnapshot {
    static func withSnapshot<T>(of source: URL, fileManager: FileManager, body: (URL) throws -> T) throws -> T {
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("remembar-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let snapshot = temporaryDirectory.appendingPathComponent(source.lastPathComponent)
        try fileManager.copyItem(at: source, to: snapshot)
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: "\(source.path)\(suffix)")
            if fileManager.fileExists(atPath: sidecar.path) {
                try fileManager.copyItem(at: sidecar, to: URL(fileURLWithPath: "\(snapshot.path)\(suffix)"))
            }
        }
        return try body(snapshot)
    }
}

private final class SQLiteDatabase {
    private var handle: OpaquePointer?

    init(url: URL) throws {
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        let uri = "file:\(url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path)?mode=ro"
        guard sqlite3_open_v2(uri, &handle, flags, nil) == SQLITE_OK else {
            throw SQLiteError.open(message: String(cString: sqlite3_errmsg(handle)))
        }
    }

    func close() {
        if handle != nil {
            sqlite3_close(handle)
            handle = nil
        }
    }

    func query<T>(_ sql: String, row: (SQLiteStatement) throws -> T?) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.prepare(message: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }

        var rows: [T] = []
        while true {
            let result = sqlite3_step(statement)
            switch result {
            case SQLITE_ROW:
                if let item = try row(SQLiteStatement(statement: statement)) {
                    rows.append(item)
                }
            case SQLITE_DONE:
                return rows
            default:
                throw SQLiteError.step(message: String(cString: sqlite3_errmsg(handle)))
            }
        }
    }
}

private struct SQLiteStatement {
    let statement: OpaquePointer?

    func int64(at index: Int32) -> Int64 {
        sqlite3_column_int64(statement, index)
    }

    func double(at index: Int32) -> Double {
        sqlite3_column_double(statement, index)
    }

    func text(at index: Int32) -> String {
        guard let text = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: text)
    }
}

private enum SQLiteError: Error, CustomStringConvertible {
    case open(message: String)
    case prepare(message: String)
    case step(message: String)

    var description: String {
        switch self {
        case .open(let message):
            return "SQLite open failed: \(message)"
        case .prepare(let message):
            return "SQLite prepare failed: \(message)"
        case .step(let message):
            return "SQLite step failed: \(message)"
        }
    }
}

private extension Array where Element == HistorySource {
    func uniqueByPath() -> [HistorySource] {
        var seen = Set<String>()
        return filter { seen.insert($0.url.path).inserted }
    }
}

extension MemoryResult {
    init(historyItem: HistoryItem, rank: Int = 0) {
        let title = historyItem.title.isEmpty ? historyItem.url.absoluteString : historyItem.title
        self.init(
            id: "\(historyItem.sourcePath)|\(historyItem.url.absoluteString)|\(historyItem.visitedAt.timeIntervalSince1970)",
            title: title,
            detail: "\(historyItem.browser.displayName) · \(historyItem.visitedAt.formatted(.dateTime.month().day())) · \(historyItem.url.host() ?? historyItem.url.absoluteString)",
            refinedDetail: nil,
            url: historyItem.url,
            thumbnailURL: historyItem.url.thumbnailURL,
            browser: historyItem.browser,
            rank: rank
        )
    }
}

private extension URL {
    var thumbnailURL: URL? {
        let resultKind = HistoryResultKind(url: self)
        if let videoID = resultKind.videoID {
            return URL(string: "https://img.youtube.com/vi/\(videoID)/hqdefault.jpg")
        }
        if isYouTubeURL {
            return nil
        }
        guard let host, !host.isLocalHost else { return nil }
        return URL(string: "https://www.google.com/s2/favicons?domain=\(host)&sz=128")
    }
}

private extension String {
    var isLocalHost: Bool {
        let lowercasedHost = lowercased()
        return lowercasedHost == "localhost" ||
            lowercasedHost.hasSuffix(".local") ||
            lowercasedHost.hasPrefix("127.") ||
            lowercasedHost == "::1"
    }
}
