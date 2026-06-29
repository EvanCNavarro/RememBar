import Foundation

struct OnePasswordSearchProvider: MemorySearching, Sendable {
    private let itemLister: any OnePasswordItemListing
    private let diagnostics: RememBarDiagnostics

    init(
        itemLister: (any OnePasswordItemListing)? = nil,
        diagnostics: RememBarDiagnostics = .shared
    ) {
        self.itemLister = itemLister ?? OnePasswordCLIItemLister()
        self.diagnostics = diagnostics
    }

    func searchResponse(query: String, refinements: [String], limit: Int) async -> MemorySearchResponse {
        let terms = MemorySearchTokenizer.tokenize(([query] + refinements).joined(separator: " "))
        guard !terms.isEmpty else {
            return MemorySearchResponse(sourceStatuses: [Self.status(state: .skipped, detail: "No search terms")])
        }

        do {
            let items = try await itemLister.listItems()
            let results = items
                .compactMap { item -> (MemoryResult, Int)? in
                    let score = Self.score(item: item, terms: terms)
                    guard score > 0 else { return nil }
                    return (MemoryResult(onePasswordItem: item, rank: score), score)
                }
                .sorted { lhs, rhs in
                    if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                    return lhs.0.title.localizedCaseInsensitiveCompare(rhs.0.title) == .orderedAscending
                }
                .prefix(limit)
                .map(\.0)

            return MemorySearchResponse(
                results: results,
                sourceStatuses: [Self.status(state: .searched, detail: "\(items.count) visible items")]
            )
        } catch let error as OnePasswordItemListError {
            return MemorySearchResponse(sourceStatuses: [Self.status(for: error)])
        } catch is CancellationError {
            return MemorySearchResponse(sourceStatuses: [Self.status(state: .skipped, detail: "Search cancelled")])
        } catch {
            diagnostics.record(
                RememBarDiagnosticEvent.onePasswordProviderFailed,
                level: .error,
                fields: ["errorType": String(reflecting: type(of: error))]
            )
            return MemorySearchResponse(sourceStatuses: [Self.status(state: .failed, detail: "Could not read item metadata")])
        }
    }

    private static func score(item: OnePasswordItemSummary, terms: [String]) -> Int {
        let titleTokens = Set(MemorySearchTokenizer.tokenize(item.title))
        let vaultTokens = Set(MemorySearchTokenizer.tokenize(item.vaultName))
        let categoryTokens = Set(MemorySearchTokenizer.tokenize(item.categoryDisplayName))
        var score = 0
        for term in terms {
            if titleTokens.contains(term) {
                score += 120
            } else if vaultTokens.contains(term) {
                score += 35
            } else if categoryTokens.contains(term) {
                score += 25
            }
        }
        if item.title.localizedCaseInsensitiveContains(terms.joined(separator: " ")) {
            score += 200
        }
        return score
    }

    private static func status(for error: OnePasswordItemListError) -> MemorySearchSourceStatus {
        switch error {
        case .unavailable:
            return status(state: .unavailable, detail: "1Password CLI is not installed")
        case .locked:
            return status(state: .blocked, detail: "Unlock or sign in to 1Password")
        case .failed:
            return status(state: .failed, detail: "Could not read item metadata")
        }
    }

    private static func status(state: MemorySearchSourceStatus.State, detail: String) -> MemorySearchSourceStatus {
        MemorySearchSourceStatus(
            id: "1password",
            sourceName: "1Password",
            state: state,
            detail: detail
        )
    }
}

protocol OnePasswordItemListing: Sendable {
    func listItems() async throws -> [OnePasswordItemSummary]
}

struct OnePasswordItemSummary: Equatable, Sendable {
    let id: String
    let title: String
    let vaultID: String
    let vaultName: String
    let category: String

    var categoryDisplayName: String {
        category
            .split(separator: "_")
            .map { word in
                word.prefix(1).uppercased() + word.dropFirst().lowercased()
            }
            .joined(separator: " ")
    }
}

enum OnePasswordItemListError: Error, Equatable {
    case unavailable
    case locked
    case failed
}

struct OnePasswordCLIItemLister: OnePasswordItemListing {
    private let executableURL: URL?
    private let timeout: DispatchTimeInterval

    init(
        executableURL: URL? = Self.defaultExecutableURL(),
        timeout: DispatchTimeInterval = .seconds(4)
    ) {
        self.executableURL = executableURL
        self.timeout = timeout
    }

    func listItems() async throws -> [OnePasswordItemSummary] {
        guard let executableURL else { throw OnePasswordItemListError.unavailable }
        let state = RunningProcessState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        continuation.resume(returning: try Self.run(
                            executableURL: executableURL,
                            timeout: timeout,
                            state: state
                        ))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            state.cancel()
        }
    }

    static func decodeItems(from data: Data) throws -> [OnePasswordItemSummary] {
        try JSONDecoder().decode([DecodedOnePasswordItem].self, from: data).map {
            OnePasswordItemSummary(
                id: $0.id,
                title: $0.title,
                vaultID: $0.vault.id,
                vaultName: $0.vault.name,
                category: $0.category
            )
        }
    }

    private static func run(
        executableURL: URL,
        timeout: DispatchTimeInterval,
        state: RunningProcessState
    ) throws -> [OnePasswordItemSummary] {
        try Task.checkCancellation()

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["item", "list", "--format", "json"]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let finished = DispatchSemaphore(value: 0)
        let outputFinished = DispatchSemaphore(value: 0)
        let errorFinished = DispatchSemaphore(value: 0)
        let outputData = LockedData()
        let errorData = LockedData()
        process.terminationHandler = { _ in finished.signal() }

        if state.isCancelled {
            throw CancellationError()
        }

        do {
            try process.run()
        } catch {
            throw OnePasswordItemListError.unavailable
        }
        state.attachLaunched(process)

        DispatchQueue.global(qos: .utility).async {
            outputData.set(outputPipe.fileHandleForReading.readDataToEndOfFile())
            outputFinished.signal()
        }
        DispatchQueue.global(qos: .utility).async {
            errorData.set(errorPipe.fileHandleForReading.readDataToEndOfFile())
            errorFinished.signal()
        }

        if state.isCancelled, process.isRunning {
            process.terminate()
        }

        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            _ = finished.wait(timeout: .now() + .seconds(1))
            outputPipe.fileHandleForReading.closeFile()
            errorPipe.fileHandleForReading.closeFile()
            _ = outputFinished.wait(timeout: .now() + .seconds(1))
            _ = errorFinished.wait(timeout: .now() + .seconds(1))
            throw OnePasswordItemListError.failed
        }

        _ = outputFinished.wait(timeout: .now() + .seconds(1))
        _ = errorFinished.wait(timeout: .now() + .seconds(1))

        if state.isCancelled {
            throw CancellationError()
        }

        let output = outputData.get()
        let errorOutput = errorData.get()
        guard process.terminationStatus == 0 else {
            let stderr = String(data: errorOutput, encoding: .utf8)?.lowercased() ?? ""
            if stderr.contains("sign in") || stderr.contains("not currently signed in") || stderr.contains("unlock") {
                throw OnePasswordItemListError.locked
            }
            throw OnePasswordItemListError.failed
        }

        do {
            return try decodeItems(from: output)
        } catch {
            throw OnePasswordItemListError.failed
        }
    }

    private static func defaultExecutableURL(fileManager: FileManager = .default) -> URL? {
        [
            "/opt/homebrew/bin/op",
            "/usr/local/bin/op",
            "/usr/bin/op"
        ]
            .map(URL.init(fileURLWithPath:))
            .first { fileManager.isExecutableFile(atPath: $0.path) }
    }
}

private struct DecodedOnePasswordItem: Decodable {
    struct Vault: Decodable {
        let id: String
        let name: String
    }

    let id: String
    let title: String
    let vault: Vault
    let category: String
}

private extension MemoryResult {
    init(onePasswordItem item: OnePasswordItemSummary, rank: Int) {
        self.init(
            id: "1password|\(item.vaultID)|\(item.id)",
            title: item.title,
            detail: "1Password · \(item.vaultName) · \(item.categoryDisplayName)",
            externalApp: ExternalAppTarget.onePassword()!,
            rank: rank
        )
    }
}
