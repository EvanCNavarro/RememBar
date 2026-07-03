import Foundation

struct CompositeMemorySearchProvider: MemorySearching, Sendable {
    /// When set, these fixed providers are used verbatim (test injection) and the catalog/factory are
    /// bypassed. When nil, providers are built PER SEARCH from `catalog.snapshot` so an in-app edit to
    /// the term families is live on the very next search — no app restart, no provider rebuild.
    private let staticProviders: [any MemorySearching]?
    private let catalog: AliasCatalog
    private let makeProviders: @Sendable (AliasGroups) -> [any MemorySearching]
    private let diagnostics: RememBarDiagnostics

    init(
        providers: [any MemorySearching]? = nil,
        catalog: AliasCatalog = AliasCatalog(),
        diagnostics: RememBarDiagnostics = .shared,
        providerFactory: (@Sendable (AliasGroups) -> [any MemorySearching])? = nil
    ) {
        self.staticProviders = providers
        self.catalog = catalog
        self.diagnostics = diagnostics
        self.makeProviders = providerFactory ?? { aliases in
            [
                SpotlightFileSearchProvider(diagnostics: diagnostics, aliases: aliases),
                LocalHistorySearchProvider(diagnostics: diagnostics, aliases: aliases),
                OnePasswordSearchProvider(diagnostics: diagnostics, aliases: aliases)
            ]
        }
    }

    func searchResponse(query: String, refinements: [String], limit: Int) async -> MemorySearchResponse {
        let startedAt = Date()
        // Read the live families ONCE per search (thread-safe snapshot) and build providers from it,
        // unless fixed providers were injected. This is the live-reload seam.
        let providers = staticProviders ?? makeProviders(catalog.snapshot)
        diagnostics.record(
            RememBarDiagnosticEvent.compositeSearchStarted,
            fields: [
                "query": query,
                "refinementCount": "\(refinements.count)",
                "limit": "\(limit)",
                "providerCount": "\(providers.count)"
            ]
        )
        let response = await withTaskGroup(of: ProviderSearchOutput.self) { group in
            for (index, provider) in providers.enumerated() {
                group.addTask {
                    await self.runProvider(
                        provider,
                        index: index,
                        query: query,
                        refinements: refinements,
                        limit: limit
                    )
                }
            }

            var outputs: [ProviderSearchOutput] = []
            for await output in group {
                outputs.append(output)
            }
            let orderedOutputs = outputs.sorted { $0.index < $1.index }
            let results = orderedOutputs.flatMap(\.response.results)
            let sourceStatuses = orderedOutputs.flatMap(\.response.sourceStatuses)
            return MemorySearchResponse(
                results: MemoryResultMerger.merge(results, limit: limit),
                sourceStatuses: MemorySourceStatusMerger.merge(sourceStatuses)
            )
        }
        diagnostics.record(
            RememBarDiagnosticEvent.compositeSearchFinished,
            fields: [
                "query": query,
                "resultCount": "\(response.results.count)",
                "sourceStatusCount": "\(response.sourceStatuses.count)",
                "durationMs": "\(Int(Date().timeIntervalSince(startedAt) * 1000))",
                "topResultIDs": response.results.prefix(5).map(\.id).joined(separator: ",")
            ]
        )
        return response
    }

    private func runProvider(
        _ provider: any MemorySearching,
        index: Int,
        query: String,
        refinements: [String],
        limit: Int
    ) async -> ProviderSearchOutput {
        let providerName = String(describing: type(of: provider))
        let providerStartedAt = Date()
        diagnostics.record(
            RememBarDiagnosticEvent.compositeProviderStarted,
            fields: ["provider": providerName, "query": query]
        )
        let response = await provider.searchResponse(query: query, refinements: refinements, limit: limit)
        diagnostics.record(
            RememBarDiagnosticEvent.compositeProviderFinished,
            fields: [
                "provider": providerName,
                "query": query,
                "resultCount": "\(response.results.count)",
                "sourceStatusCount": "\(response.sourceStatuses.count)",
                "durationMs": "\(Int(Date().timeIntervalSince(providerStartedAt) * 1000))"
            ]
        )
        return ProviderSearchOutput(index: index, response: response)
    }
}

private struct ProviderSearchOutput: Sendable {
    let index: Int
    let response: MemorySearchResponse
}

private enum MemoryResultMerger {
    static func merge(_ results: [MemoryResult], limit: Int) -> [MemoryResult] {
        var bestByID: [MemoryResult.ID: MemoryResult] = [:]
        for result in results {
            if let existing = bestByID[result.id] {
                if isBetter(result, than: existing) {
                    bestByID[result.id] = result
                }
            } else {
                bestByID[result.id] = result
            }
        }

        return bestByID.values
            .sorted(by: isBetter)
            .prefix(limit)
            .map { $0 }
    }

    private static func isBetter(_ lhs: MemoryResult, than rhs: MemoryResult) -> Bool {
        if lhs.rank != rhs.rank {
            return lhs.rank > rhs.rank
        }

        let titleOrder = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
        if titleOrder != .orderedSame {
            return titleOrder == .orderedAscending
        }

        if lhs.id != rhs.id {
            return lhs.id < rhs.id
        }

        return lhs.url.absoluteString < rhs.url.absoluteString
    }
}

private enum MemorySourceStatusMerger {
    static func merge(_ statuses: [MemorySearchSourceStatus]) -> [MemorySearchSourceStatus] {
        var merged: [String: MemorySearchSourceStatus] = [:]
        var orderedIDs: [String] = []
        for status in statuses {
            if merged[status.id] == nil {
                orderedIDs.append(status.id)
                merged[status.id] = status
                continue
            }
            if let existing = merged[status.id], status.state.severity > existing.state.severity {
                merged[status.id] = status
            }
        }
        return orderedIDs.compactMap { merged[$0] }
    }
}

private extension MemorySearchSourceStatus.State {
    var severity: Int {
        switch self {
        case .blocked:
            return 5
        case .failed:
            return 4
        case .unavailable:
            return 3
        case .skipped:
            return 2
        case .searched:
            return 1
        }
    }
}
