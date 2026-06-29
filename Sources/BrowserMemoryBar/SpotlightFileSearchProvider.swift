import Foundation

struct SpotlightFileSearchProvider: MemorySearching, Sendable {
    private let home: URL
    private let spotlight: any SpotlightSearching
    private let accessChecker: any FileSearchAccessChecking
    private let now: @Sendable () -> Date
    private let diagnostics: RememBarDiagnostics

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        spotlight: (any SpotlightSearching)? = nil,
        accessChecker: any FileSearchAccessChecking = ProtectedLocationFileSearchAccessChecker(),
        now: @escaping @Sendable () -> Date = Date.init,
        diagnostics: RememBarDiagnostics = .shared
    ) {
        self.home = home
        self.spotlight = spotlight ?? MdfindSpotlightSearch(diagnostics: diagnostics)
        self.accessChecker = accessChecker
        self.now = now
        self.diagnostics = diagnostics
    }

    func searchResponse(query: String, refinements: [String], limit: Int) async -> MemorySearchResponse {
        let plan = SpotlightFileQueryPlan(query: query, refinements: refinements)
        guard !plan.query.isEmpty else {
            diagnostics.record(
                RememBarDiagnosticEvent.spotlightProviderEmptyPlan,
                fields: [
                    "query": query,
                    "refinementCount": "\(refinements.count)"
                ]
            )
            return MemorySearchResponse(sourceStatuses: [
                MemorySearchSourceStatus(
                    id: "files",
                    sourceName: "Files",
                    state: .skipped,
                    detail: "No file-search terms"
                )
            ])
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
        if !accessIssues.isEmpty {
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
        do {
            let urls = try await spotlight.search(query: plan.query, root: home)
            let fileResults = FileResultRanker
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
            let results = Self.results(
                fileResults: fileResults,
                limit: limit
            )
            let sourceStatuses = Self.sourceStatuses(
                candidateCount: urls.count,
                resultCount: fileResults.count,
                accessIssues: accessIssues
            )
            diagnostics.record(
                RememBarDiagnosticEvent.spotlightProviderFinished,
                fields: [
                    "query": query,
                    "candidateCount": "\(urls.count)",
                    "accessIssueCount": "\(accessIssues.count)",
                    "resultCount": "\(results.count)",
                    "sourceStatusCount": "\(sourceStatuses.count)",
                    "durationMs": "\(Int(Date().timeIntervalSince(startedAt) * 1000))",
                    "topResultIDs": results.prefix(5).map(\.id).joined(separator: ",")
                ]
            )
            return MemorySearchResponse(results: results, sourceStatuses: sourceStatuses)
        } catch {
            let status = MemorySearchSourceStatus(
                id: "files",
                sourceName: "Files",
                state: .failed,
                detail: "File search failed"
            )
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
            return MemorySearchResponse(sourceStatuses: [status])
        }
    }

    private static func results(fileResults: [MemoryResult], limit: Int) -> [MemoryResult] {
        fileResults
            .prefix(limit)
            .map { $0 }
    }

    private static func sourceStatuses(
        candidateCount: Int,
        resultCount: Int,
        accessIssues: [FileSearchAccessIssue]
    ) -> [MemorySearchSourceStatus] {
        var statuses = [
            MemorySearchSourceStatus(
                id: "files",
                sourceName: "Files",
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

    private static func sourceIDComponent(_ value: String) -> String {
        value.slugified()
    }
}
