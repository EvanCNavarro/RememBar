import Foundation

struct SpotlightFileSearchProvider: MemorySearching, Sendable {
    private let home: URL
    private let spotlight: any SpotlightSearching
    private let accessChecker: any FileSearchAccessChecking
    private let now: @Sendable () -> Date
    private let diagnostics: RememBarDiagnostics
    private let aliases: AliasGroups

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        spotlight: (any SpotlightSearching)? = nil,
        accessChecker: any FileSearchAccessChecking = ProtectedLocationFileSearchAccessChecker(),
        now: @escaping @Sendable () -> Date = Date.init,
        diagnostics: RememBarDiagnostics = .shared,
        aliases: AliasGroups = .empty
    ) {
        self.home = home
        self.spotlight = spotlight ?? MdfindSpotlightSearch(diagnostics: diagnostics)
        self.accessChecker = accessChecker
        self.now = now
        self.diagnostics = diagnostics
        self.aliases = aliases
    }

    func searchResponse(query: String, refinements: [String], limit: Int) async -> MemorySearchResponse {
        let plan = SpotlightFileQueryPlan(query: query, refinements: refinements, aliases: aliases)
        guard !plan.query.isEmpty else {
            return skippedResponse(query: query, refinements: refinements)
        }

        let startedAt = Date()
        diagnostics.record(
            RememBarDiagnosticEvent.spotlightProviderStarted,
            fields: [
                "query": query,
                "spotlightQuery": plan.query,
                "root": home.path,
                "refinementCount": "\(refinements.count)",
                "limit": "\(limit)"
            ]
        )
        let accessIssues = plan.hasExplicitFileIntent ? accessChecker.inaccessibleLocations(home: home) : []
        recordAccessIssues(accessIssues, query: query)
        do {
            let urls = try await spotlight.search(query: plan.query, root: home)
            return makeResponse(
                urls: urls,
                plan: plan,
                limit: limit,
                accessIssues: accessIssues,
                logging: (query: query, startedAt: startedAt)
            )
        } catch {
            diagnostics.record(
                RememBarDiagnosticEvent.spotlightProviderFailed,
                level: .error,
                fields: [
                    "query": query,
                    "spotlightQuery": plan.query,
                    "root": home.path,
                    "error": String(describing: error),
                    "durationMs": "\(Int(Date().timeIntervalSince(startedAt) * 1000))"
                ]
            )
            return MemorySearchResponse(
                sourceStatuses: [Self.filesStatus(state: .failed, detail: "File search failed")]
            )
        }
    }

    private func skippedResponse(query: String, refinements: [String]) -> MemorySearchResponse {
        diagnostics.record(
            RememBarDiagnosticEvent.spotlightProviderEmptyPlan,
            fields: [
                "query": query,
                "refinementCount": "\(refinements.count)"
            ]
        )
        return MemorySearchResponse(
            sourceStatuses: [Self.filesStatus(state: .skipped, detail: "No file-search terms")]
        )
    }

    private func recordAccessIssues(_ accessIssues: [FileSearchAccessIssue], query: String) {
        guard !accessIssues.isEmpty else { return }
        diagnostics.record(
            RememBarDiagnosticEvent.fileSearchAccessDenied,
            level: .warning,
            fields: [
                "query": query,
                "locationNames": accessIssues.map(\.locationName).joined(separator: ","),
                "paths": accessIssues.map(\.path).joined(separator: ","),
                "reasons": accessIssues.map(\.reason).joined(separator: ",")
            ]
        )
    }

    private func makeResponse(
        urls: [URL],
        plan: SpotlightFileQueryPlan,
        limit: Int,
        accessIssues: [FileSearchAccessIssue],
        logging: (query: String, startedAt: Date)
    ) -> MemorySearchResponse {
        let results = FileResultRanker
            .rank(urls: urls, plan: plan, home: home, now: now())
            .prefix(limit)
            .map {
                MemoryResult(
                    fileURL: $0.url,
                    displayPath: $0.displayPath,
                    modifiedAt: $0.modifiedAt,
                    rank: $0.score
                )
            }
        let sourceStatuses = Self.sourceStatuses(
            candidateCount: urls.count,
            resultCount: results.count,
            accessIssues: accessIssues
        )
        diagnostics.record(
            RememBarDiagnosticEvent.spotlightProviderFinished,
            fields: [
                "query": logging.query,
                "candidateCount": "\(urls.count)",
                "accessIssueCount": "\(accessIssues.count)",
                "resultCount": "\(results.count)",
                "sourceStatusCount": "\(sourceStatuses.count)",
                "durationMs": "\(Int(Date().timeIntervalSince(logging.startedAt) * 1000))",
                "topResultIDs": results.prefix(5).map(\.id).joined(separator: ",")
            ]
        )
        return MemorySearchResponse(results: results, sourceStatuses: sourceStatuses)
    }

    private static func sourceStatuses(
        candidateCount: Int,
        resultCount: Int,
        accessIssues: [FileSearchAccessIssue]
    ) -> [MemorySearchSourceStatus] {
        var statuses = [
            filesStatus(
                state: .searched,
                detail: "\(resultCount) results from \(candidateCount) Spotlight candidates"
            )
        ]
        statuses.append(contentsOf: accessIssues.map { issue in
            MemorySearchSourceStatus(
                id: "files.access.\(sourceIDComponent(issue.locationName))",
                sourceName: issue.locationName,
                state: .blocked,
                detail: "Permission required"
            )
        })
        return statuses
    }

    private static func filesStatus(
        state: MemorySearchSourceStatus.State,
        detail: String
    ) -> MemorySearchSourceStatus {
        MemorySearchSourceStatus(
            id: "files",
            sourceName: "Files",
            state: state,
            detail: detail
        )
    }

    private static func sourceIDComponent(_ value: String) -> String {
        value.slugified()
    }
}
