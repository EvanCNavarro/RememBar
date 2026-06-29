import Foundation

protocol SpotlightSearching: Sendable {
    func search(query: String, root: URL) async throws -> [URL]
}

struct MdfindSpotlightSearch: SpotlightSearching, Sendable {
    private let executableURL: URL
    private let timeout: DispatchTimeInterval
    private let diagnostics: RememBarDiagnostics

    init(
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/mdfind"),
        timeout: DispatchTimeInterval = .seconds(4),
        diagnostics: RememBarDiagnostics = .shared
    ) {
        self.executableURL = executableURL
        self.timeout = timeout
        self.diagnostics = diagnostics
    }

    func search(query: String, root: URL) async throws -> [URL] {
        let state = RunningProcessState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        continuation.resume(returning: try run(query: query, root: root, state: state))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            diagnostics.record(
                RememBarDiagnosticEvent.mdfindSearchCancelRequested,
                level: .warning,
                fields: processFields(query: query, root: root)
            )
            state.cancel()
        }
    }

    private func run(query: String, root: URL, state: RunningProcessState) throws -> [URL] {
        try Task.checkCancellation()

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["-onlyin", root.path, query]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let processFinished = DispatchSemaphore(value: 0)
        let outputFinished = DispatchSemaphore(value: 0)
        let output = LockedData()

        process.terminationHandler = { _ in
            processFinished.signal()
        }

        if state.isCancelled {
            diagnostics.record(
                RememBarDiagnosticEvent.mdfindProcessCancelledBeforeLaunch,
                level: .warning,
                fields: processFields(query: query, root: root)
            )
            throw CancellationError()
        }
        diagnostics.record(RememBarDiagnosticEvent.mdfindProcessLaunch, fields: processFields(query: query, root: root))
        do {
            try process.run()
        } catch {
            var fields = processFields(query: query, root: root)
            fields["error"] = String(describing: error)
            diagnostics.record(RememBarDiagnosticEvent.mdfindProcessLaunchFailed, level: .error, fields: fields)
            throw error
        }
        state.attachLaunched(process)
        diagnostics.record(
            RememBarDiagnosticEvent.mdfindProcessLaunched,
            fields: processFields(query: query, root: root, processID: process.processIdentifier)
        )
        DispatchQueue.global(qos: .utility).async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            output.set(data)
            outputFinished.signal()
        }
        if state.isCancelled, process.isRunning {
            diagnostics.record(
                RememBarDiagnosticEvent.mdfindProcessCancelRequestedAfterLaunch,
                level: .warning,
                fields: processFields(query: query, root: root, processID: process.processIdentifier)
            )
            process.terminate()
        }
        guard processFinished.wait(timeout: .now() + timeout) == .success else {
            diagnostics.record(
                RememBarDiagnosticEvent.mdfindProcessTimeout,
                level: .error,
                fields: processFields(query: query, root: root, processID: process.processIdentifier)
            )
            process.terminate()
            _ = processFinished.wait(timeout: .now() + .seconds(1))
            pipe.fileHandleForReading.closeFile()
            _ = outputFinished.wait(timeout: .now() + .seconds(1))
            throw SpotlightSearchError.timedOut
        }
        _ = outputFinished.wait(timeout: .now() + .seconds(1))

        let text = String(data: output.get(), encoding: .utf8) ?? ""
        if state.isCancelled {
            diagnostics.record(
                RememBarDiagnosticEvent.mdfindProcessCancelled,
                level: .warning,
                fields: processFields(query: query, root: root, processID: process.processIdentifier)
            )
            throw CancellationError()
        }
        if process.terminationStatus != 0 {
            var fields = processFields(query: query, root: root, processID: process.processIdentifier)
            fields["terminationStatus"] = "\(process.terminationStatus)"
            fields["stderr"] = text.trimmingCharacters(in: .whitespacesAndNewlines)
            diagnostics.record(RememBarDiagnosticEvent.mdfindProcessFailed, level: .error, fields: fields)
            throw SpotlightSearchError.mdfindFailed(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let urls = text
            .split(separator: "\n")
            .map { URL(fileURLWithPath: String($0)) }
        var fields = processFields(query: query, root: root, processID: process.processIdentifier)
        fields["terminationStatus"] = "\(process.terminationStatus)"
        fields["resultCount"] = "\(urls.count)"
        diagnostics.record(RememBarDiagnosticEvent.mdfindProcessFinished, fields: fields)
        return urls
    }

    private func processFields(query: String, root: URL, processID: Int32? = nil) -> [String: String] {
        var fields = [
            "executable": executableURL.path,
            "root": root.path,
            "query": query,
            "timeout": "\(timeout)"
        ]
        if let processID {
            fields["childProcessID"] = "\(processID)"
        }
        return fields
    }
}

enum SpotlightSearchError: Error, Equatable {
    case mdfindFailed(String)
    case timedOut
}
