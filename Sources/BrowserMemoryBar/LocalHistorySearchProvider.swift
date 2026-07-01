import Foundation
import SQLite3

struct LocalHistorySearchProvider: MemorySearching, Sendable {
    private let home: URL
    private let window: HistorySearchWindow
    private let diagnostics: RememBarDiagnostics
    private let aliases: AliasGroups

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        window: HistorySearchWindow = .default,
        diagnostics: RememBarDiagnostics = .shared,
        aliases: AliasGroups = .empty
    ) {
        self.home = home
        self.window = window
        self.diagnostics = diagnostics
        self.aliases = aliases
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
        let results = HistoryRanker.searchRanked(
            rows: report.rows,
            query: query,
            refinements: refinements,
            limit: limit,
            aliases: aliases
        )
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
        let sourceReads = discoveryReport.sources.map { readSource($0, since: since) }
        return HistoryReadReport(sourceReads: sourceReads, discoveryIssues: discoveryReport.issues)
    }

    private func readSource(_ source: HistorySource, since: Date?) -> HistorySourceRead {
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
        value.slugified()
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
        "\(browser.displayName).\(profile)".slugified()
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

private extension Array where Element == HistorySource {
    func uniqueByPath() -> [HistorySource] {
        var seen = Set<String>()
        return filter { seen.insert($0.url.path).inserted }
    }
}

extension MemoryResult {
    init(historyItem: HistoryItem, rank: Int = 0) {
        let title = historyItem.title.isEmpty ? historyItem.url.absoluteString : historyItem.title
        let visitedTimestamp = historyItem.visitedAt.timeIntervalSince1970
        let id = "\(historyItem.sourcePath)|\(historyItem.url.absoluteString)|\(visitedTimestamp)"
        let host = historyItem.url.host() ?? historyItem.url.absoluteString
        let day = historyItem.visitedAt.formatted(.dateTime.month().day())
        let detail = "\(historyItem.browser.displayName) · \(day) · \(host)"
        self.init(
            id: id,
            title: title,
            detail: detail,
            refinedDetail: nil,
            url: historyItem.url,
            thumbnailURL: historyItem.url.thumbnailURL,
            browser: historyItem.browser,
            rank: rank,
            visitedAt: historyItem.visitedAt
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
