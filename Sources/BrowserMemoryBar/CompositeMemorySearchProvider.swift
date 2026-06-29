import Foundation

struct CompositeMemorySearchProvider: MemorySearching, Sendable {
    private let providers: [any MemorySearching]
    private let diagnostics: RememBarDiagnostics

    init(providers: [any MemorySearching]? = nil, diagnostics: RememBarDiagnostics = .shared) {
        self.diagnostics = diagnostics
        self.providers = providers ?? [
            SpotlightFileSearchProvider(diagnostics: diagnostics),
            LocalHistorySearchProvider(diagnostics: diagnostics),
            OnePasswordSearchProvider(diagnostics: diagnostics)
        ]
    }

    func searchResponse(query: String, refinements: [String], limit: Int) async -> MemorySearchResponse {
        let startedAt = Date()
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
                let providerName = String(describing: type(of: provider))
                let diagnostics = diagnostics
                group.addTask {
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
