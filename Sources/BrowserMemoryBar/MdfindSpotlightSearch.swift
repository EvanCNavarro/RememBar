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
        diagnostics.record(RememBarDiagnosticEvent.mdfindProcessLaunch, fields: processFields(query: query, root: root))
        let result: ProcessRunResult
        do {
            result = try ProcessRunner.run(
                executableURL: executableURL,
                arguments: ["-onlyin", root.path, query],
                timeout: timeout,
                state: state,
                separateStderr: false, // mdfind merges stderr into stdout
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
        } catch ProcessRunError.cancelledBeforeLaunch {
            diagnostics.record(
                RememBarDiagnosticEvent.mdfindProcessCancelledBeforeLaunch,
                level: .warning,
                fields: processFields(query: query, root: root)
            )
            throw CancellationError()
        } catch let ProcessRunError.launchFailed(error) {
            var fields = processFields(query: query, root: root)
            fields["error"] = String(describing: error)
            diagnostics.record(RememBarDiagnosticEvent.mdfindProcessLaunchFailed, level: .error, fields: fields)
            throw error
        } catch let ProcessRunError.timedOut(pid) {
            diagnostics.record(
                RememBarDiagnosticEvent.mdfindProcessTimeout,
                level: .error,
                fields: processFields(query: query, root: root, processID: pid)
            )
            throw SpotlightSearchError.timedOut
        } catch let ProcessRunError.cancelledAfterLaunch(pid) {
            diagnostics.record(
                RememBarDiagnosticEvent.mdfindProcessCancelled,
                level: .warning,
                fields: processFields(query: query, root: root, processID: pid)
            )
            throw CancellationError()
        }

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
            .map { URL(fileURLWithPath: String($0)) }
        var fields = processFields(query: query, root: root, processID: result.processID)
        fields["terminationStatus"] = "\(result.terminationStatus)"
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
