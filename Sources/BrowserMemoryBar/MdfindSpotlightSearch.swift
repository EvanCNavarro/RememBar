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
        let result = try launch(query: query, root: root, state: state)

        let text = String(data: result.stdout, encoding: .utf8) ?? ""
        if result.terminationStatus != 0 {
            var fields = processFields(query: query, root: root, processID: result.processID)
            fields["terminationStatus"] = "\(result.terminationStatus)"
            fields["stderr"] = text.trimmingCharacters(in: .whitespacesAndNewlines)
            diagnostics.record(RememBarDiagnosticEvent.mdfindProcessFailed, level: .error, fields: fields)
            throw SpotlightSearchError.mdfindFailed(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let urls = text
            .split(separator: "\n")
            // mdfind's stderr is merged into stdout (separateStderr: false), so a diagnostic line on
            // an otherwise-successful run can appear here — keep only absolute file paths.
            .filter { $0.hasPrefix("/") }
            .map { URL(fileURLWithPath: String($0)) }
        var fields = processFields(query: query, root: root, processID: result.processID)
        fields["terminationStatus"] = "\(result.terminationStatus)"
        fields["resultCount"] = "\(urls.count)"
        diagnostics.record(RememBarDiagnosticEvent.mdfindProcessFinished, fields: fields)
        return urls
    }

    private func launch(query: String, root: URL, state: RunningProcessState) throws -> ProcessRunResult {
        do {
            return try ProcessRunner.run(
                executableURL: executableURL,
                arguments: ["-onlyin", root.path, query],
                timeout: timeout,
                state: state,
                separateStderr: false, // mdfind merges stderr into stdout
                onWillLaunch: {
                    diagnostics.record(
                        RememBarDiagnosticEvent.mdfindProcessLaunch,
                        fields: processFields(query: query, root: root)
                    )
                },
                onLaunched: { pid in
                    diagnostics.record(
                        RememBarDiagnosticEvent.mdfindProcessLaunched,
                        fields: processFields(query: query, root: root, processID: pid)
                    )
                },
                onCancelRequestedAfterLaunch: { pid in
                    diagnostics.record(
                        RememBarDiagnosticEvent.mdfindProcessCancelRequestedAfterLaunch,
                        level: .warning,
                        fields: processFields(query: query, root: root, processID: pid)
                    )
                }
            )
        } catch {
            throw mapLaunchError(error, query: query, root: root)
        }
    }

    private func mapLaunchError(_ error: Error, query: String, root: URL) -> Error {
        switch error {
        case ProcessRunError.cancelledBeforeLaunch:
            diagnostics.record(
                RememBarDiagnosticEvent.mdfindProcessCancelledBeforeLaunch,
                level: .warning,
                fields: processFields(query: query, root: root)
            )
            return CancellationError()
        case let ProcessRunError.launchFailed(launchError):
            var fields = processFields(query: query, root: root)
            fields["error"] = String(describing: launchError)
            diagnostics.record(RememBarDiagnosticEvent.mdfindProcessLaunchFailed, level: .error, fields: fields)
            return launchError
        case let ProcessRunError.timedOut(pid), let ProcessRunError.drainIncomplete(pid):
            // Both mean "couldn't get the process's full output in time" → the same fail-loud outcome
            // (a failed source, never a silent empty result set).
            diagnostics.record(
                RememBarDiagnosticEvent.mdfindProcessTimeout,
                level: .error,
                fields: processFields(query: query, root: root, processID: pid)
            )
            return SpotlightSearchError.timedOut
        case let ProcessRunError.cancelledAfterLaunch(pid):
            diagnostics.record(
                RememBarDiagnosticEvent.mdfindProcessCancelled,
                level: .warning,
                fields: processFields(query: query, root: root, processID: pid)
            )
            return CancellationError()
        default:
            return error
        }
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
