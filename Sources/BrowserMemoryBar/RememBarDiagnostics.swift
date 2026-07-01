import Foundation

// swiftlint:disable file_length
// This file holds the diagnostics logger plus its private Codable/error companions and the extracted
// `DiagnosticLogRetention` helper (split out to keep the class body under type_body_length). Together
// they push the file just past the 500-line budget; splitting the file is out of scope here.

struct PreviousDiagnosticSession: Equatable, Sendable {
    let sessionID: String
    let startedAt: String
    let lastEventName: String?
    let lastSequence: Int
    let processID: Int32
}

final class RememBarDiagnostics: @unchecked Sendable {
    enum Level: String, Codable, Sendable {
        case debug
        case info
        case warning
        case error
    }

    static let shared = RememBarDiagnostics(
        directory: RememBarDiagnostics.defaultDirectory(),
        isEnabled: !RememBarDiagnostics.isRunningUnderTests()
    )

    let directory: URL
    let logURL: URL
    let stateURL: URL

    private let sessionID: String
    private let now: @Sendable () -> Date
    private let processID: Int32
    private let maxLogBytes: Int
    private let fileManager: FileManager
    private let isEnabled: Bool
    private let lock = NSLock()
    private static let asyncRecordQueueKey = DispatchSpecificKey<Bool>()
    private static let asyncRecordQueue: DispatchQueue = {
        let queue = DispatchQueue(label: "RememBarDiagnostics.recordAsync", qos: .utility)
        queue.setSpecific(key: asyncRecordQueueKey, value: true)
        return queue
    }()
    private var sequence = 0
    private var startedAt: String?
    private var didEndCleanly = false

    init(
        directory: URL,
        sessionID: String = UUID().uuidString,
        now: @escaping @Sendable () -> Date = Date.init,
        processID: Int32 = ProcessInfo.processInfo.processIdentifier,
        maxLogBytes: Int = 1_000_000,
        fileManager: FileManager = .default,
        isEnabled: Bool = true
    ) {
        self.directory = directory
        self.logURL = directory.appendingPathComponent("remembar-diagnostics.jsonl", isDirectory: false)
        self.stateURL = directory.appendingPathComponent("session-state.json", isDirectory: false)
        self.sessionID = sessionID
        self.now = now
        self.processID = processID
        self.maxLogBytes = maxLogBytes
        self.fileManager = fileManager
        self.isEnabled = isEnabled
    }

    @discardableResult
    func startSession(
        appVersion: String? = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
        crashReportScanner: any RememBarCrashReportScanning = RememBarCrashReportScanner()
    ) -> PreviousDiagnosticSession? {
        guard isEnabled else { return nil }
        return lock.withLock {
            ensureDirectoryExists()
            let previousState = readState()
            let startedAt = timestamp(for: now())
            self.startedAt = startedAt
            self.didEndCleanly = false

            let previous = previousState.flatMap { state -> PreviousDiagnosticSession? in
                guard state.cleanExit == false else { return nil }
                return PreviousDiagnosticSession(
                    sessionID: state.sessionID,
                    startedAt: state.startedAt,
                    lastEventName: state.lastEventName,
                    lastSequence: state.lastSequence,
                    processID: state.processID
                )
            }

            if let previous {
                recordPreviousSessionCorrelation(previous, crashReportScanner: crashReportScanner)
            }

            var fields = [
                "processID": "\(processID)",
                "logPath": logURL.path
            ]
            if let appVersion {
                fields["appVersion"] = appVersion
            }
            appendEventLocked(
                name: RememBarDiagnosticEvent.diagnosticsSessionStarted,
                level: .info,
                fields: fields,
                file: "RememBarDiagnostics",
                function: "startSession",
                line: 0
            )

            return previous
        }
    }

    /// Emits the previous-unclean-session breadcrumb, then either the matching crash report or a
    /// missing-report warning. The caller must already hold `lock` (this uses `appendEventLocked`),
    /// exactly as when this block was inline in `startSession`.
    private func recordPreviousSessionCorrelation(
        _ previous: PreviousDiagnosticSession,
        crashReportScanner: any RememBarCrashReportScanning
    ) {
        appendEventLocked(
            name: RememBarDiagnosticEvent.diagnosticsPreviousSessionUnclean,
            level: .warning,
            fields: [
                "previousSessionID": previous.sessionID,
                "startedAt": previous.startedAt,
                "lastEventName": previous.lastEventName ?? "",
                "lastSequence": "\(previous.lastSequence)",
                "processID": "\(previous.processID)"
            ],
            file: "RememBarDiagnostics",
            function: "startSession",
            line: 0
        )
        let reports = crashReportScanner.reports(
            since: Self.date(from: previous.startedAt),
            processID: previous.processID
        )
        if let report = reports.first {
            var fields = report.diagnosticFields
            fields["previousSessionID"] = previous.sessionID
            fields["lastEventName"] = previous.lastEventName ?? ""
            fields["lastSequence"] = "\(previous.lastSequence)"
            appendEventLocked(
                name: RememBarDiagnosticEvent.diagnosticsCrashReportFound,
                level: .error,
                fields: fields,
                file: "RememBarDiagnostics",
                function: "startSession",
                line: 0
            )
        } else {
            appendEventLocked(
                name: RememBarDiagnosticEvent.diagnosticsCrashReportMissing,
                level: .warning,
                fields: [
                    "previousSessionID": previous.sessionID,
                    "lastEventName": previous.lastEventName ?? "",
                    "lastSequence": "\(previous.lastSequence)",
                    "startedAt": previous.startedAt
                ],
                file: "RememBarDiagnostics",
                function: "startSession",
                line: 0
            )
        }
    }

    func endSession(reason: String) {
        guard isEnabled else { return }
        drainAsyncRecordsIfNeeded()
        lock.withLock {
            appendEventLocked(
                name: RememBarDiagnosticEvent.diagnosticsSessionEnded,
                level: .info,
                fields: ["reason": reason],
                file: "RememBarDiagnostics",
                function: "endSession",
                line: 0
            )
            writeState(
                cleanExit: true,
                lastEventName: RememBarDiagnosticEvent.diagnosticsSessionEnded,
                lastSequence: sequence,
                startedAt: startedAt ?? timestamp(for: now())
            )
        }
    }

    func record(
        _ name: String,
        level: Level = .info,
        fields: [String: String] = [:],
        file: String = #fileID,
        function: String = #function,
        line: Int = #line
    ) {
        guard isEnabled else { return }
        drainAsyncRecordsIfNeeded()
        recordSynchronously(
            name,
            level: level,
            fields: fields,
            file: file,
            function: function,
            line: line
        )
    }

    func recordAsync(
        _ name: String,
        level: Level = .info,
        fields: [String: String] = [:],
        file: String = #fileID,
        function: String = #function,
        line: Int = #line
    ) {
        guard isEnabled else { return }
        Self.asyncRecordQueue.async { [self] in
            recordSynchronously(
                name,
                level: level,
                fields: fields,
                file: file,
                function: function,
                line: line
            )
        }
    }

    // Internal logging funnel: the trailing file/function/line carry #fileID/#function/#line
    // call-site metadata and are inseparable from name/level/fields.
    // swiftlint:disable:next function_parameter_count
    private func recordSynchronously(
        _ name: String,
        level: Level,
        fields: [String: String],
        file: String,
        function: String,
        line: Int
    ) {
        lock.withLock {
            guard !didEndCleanly else { return }
            appendEventLocked(
                name: name,
                level: level,
                fields: fields,
                file: file,
                function: function,
                line: line
            )
        }
    }

    private func drainAsyncRecordsIfNeeded() {
        guard DispatchQueue.getSpecific(key: Self.asyncRecordQueueKey) != true else { return }
        Self.asyncRecordQueue.sync {}
    }

    /// Diagnostic field keys whose values may embed a filesystem path. Only these are run through
    /// path redaction, so user-typed values (`query`, `title`, `url`) are never mangled. This is
    /// the single Vector-A choke point: every written line funnels through `appendEventLocked`.
    private static let pathBearingFieldKeys: Set<String> = [
        "path", "paths", "home", "root", "sourcePath",
        "executable", "app", "logPath", "id", "target", "detail", "topResultIDs"
    ]

    private static func redactingSensitiveFields(_ fields: [String: String]) -> [String: String] {
        guard !fields.isEmpty else { return fields }
        var scrubbed = fields
        for key in pathBearingFieldKeys {
            if let value = scrubbed[key] {
                scrubbed[key] = SensitivePathPolicy.redactingSensitivePaths(in: value)
            }
        }
        return scrubbed
    }

    // Internal logging funnel: the trailing file/function/line carry #fileID/#function/#line
    // call-site metadata and are inseparable from name/level/fields.
    // swiftlint:disable:next function_parameter_count
    private func appendEventLocked(
        name: String,
        level: Level,
        fields: [String: String],
        file: String,
        function: String,
        line: Int
    ) {
        ensureDirectoryExists()
        let nextSequence = sequence + 1
        let event = DiagnosticEvent(
            timestamp: timestamp(for: now()),
            sessionID: sessionID,
            sequence: nextSequence,
            processID: processID,
            level: level,
            name: name,
            file: file,
            function: function,
            line: line,
            fields: Self.redactingSensitiveFields(fields)
        )

        do {
            let data = try Self.makeEncoder().encode(event)
            try appendLine(data)
            sequence = nextSequence
            try DiagnosticLogRetention.enforce(
                logURL: logURL,
                maxLogBytes: maxLogBytes,
                fileManager: fileManager
            )
            writeState(
                cleanExit: false,
                lastEventName: name,
                lastSequence: sequence,
                startedAt: startedAt ?? event.timestamp
            )
        } catch {
            writeFallbackLine(for: event, error: error)
        }
    }

    private func appendLine(_ data: Data) throws {
        if !fileManager.fileExists(atPath: logURL.path) {
            guard fileManager.createFile(atPath: logURL.path, contents: nil) else {
                throw DiagnosticWriteError.createFailed(logURL.path)
            }
        }
        let handle = try FileHandle(forWritingTo: logURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.write(contentsOf: Data("\n".utf8))
    }

    private func writeFallbackLine(for event: DiagnosticEvent, error: Error) {
        let fallbackEvent = DiagnosticWriteFailureEvent(
            name: RememBarDiagnosticEvent.diagnosticsWriteFailed,
            fields: [
                "event": event.name,
                "error": String(describing: error)
            ]
        )
        guard let data = try? Self.makeEncoder().encode(fallbackEvent) else { return }
        if !fileManager.fileExists(atPath: logURL.path) {
            fileManager.createFile(atPath: logURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
        try? handle.write(contentsOf: Data("\n".utf8))
    }

    private func readState() -> DiagnosticSessionState? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONDecoder().decode(DiagnosticSessionState.self, from: data)
    }

    private func writeState(cleanExit: Bool, lastEventName: String?, lastSequence: Int, startedAt: String) {
        if let current = readState(), current.sessionID != sessionID {
            if cleanExit {
                didEndCleanly = true
                return
            }
            if let currentStartedAt = Self.date(from: current.startedAt),
               let nextStartedAt = Self.date(from: startedAt),
               currentStartedAt > nextStartedAt {
                return
            }
        }

        let state = DiagnosticSessionState(
            sessionID: sessionID,
            startedAt: startedAt,
            cleanExit: cleanExit,
            lastEventName: lastEventName,
            lastSequence: lastSequence,
            processID: processID
        )
        guard let data = try? Self.makeEncoder().encode(state) else { return }
        if (try? data.write(to: stateURL, options: .atomic)) != nil, cleanExit {
            didEndCleanly = true
        }
    }

    private func ensureDirectoryExists() {
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // Shared formatter — ISO8601DateFormatter is costly to allocate and is documented thread-safe;
    // `timestamp(for:)` is on the per-event hot path. nonisolated(unsafe) vouches for that safety.
    nonisolated(unsafe) private static let iso8601 = ISO8601DateFormatter()

    private func timestamp(for date: Date) -> String {
        Self.iso8601.string(from: date)
    }

    private static func date(from timestamp: String) -> Date? {
        iso8601.date(from: timestamp)
    }

    static func defaultDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        if let override = environment["REMEMBAR_DIAGNOSTICS_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }

        let library = fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .deletingLastPathComponent()
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        return RememBarPaths(library: library, bundleURL: nil).diagnosticsDirectory
    }

    static func isRunningUnderTests(
        processName: String = ProcessInfo.processInfo.processName,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        loadedBundlePaths: [String] = Bundle.allBundles.map(\.bundlePath) + Bundle.allFrameworks.map(\.bundlePath),
        arguments: [String] = CommandLine.arguments
    ) -> Bool {
        let lowercasedProcessName = processName.lowercased()
        let lowercasedBundlePaths = loadedBundlePaths.map { $0.lowercased() }
        let lowercasedArguments = arguments.map { $0.lowercased() }
        return environment["XCTestConfigurationFilePath"] != nil ||
            lowercasedProcessName.contains("packagetests") ||
            lowercasedProcessName.contains("xctest") ||
            lowercasedBundlePaths.contains { path in
                path.hasSuffix(".xctest") || path.contains("/xctest.framework/")
            } ||
            lowercasedArguments.contains { argument in
                argument.contains(".xctest/") || argument.contains("packagetests")
            }
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private struct DiagnosticEvent: Codable {
    let timestamp: String
    let sessionID: String
    let sequence: Int
    let processID: Int32
    let level: RememBarDiagnostics.Level
    let name: String
    let file: String
    let function: String
    let line: Int
    let fields: [String: String]
}

private struct DiagnosticSessionState: Codable {
    let sessionID: String
    let startedAt: String
    let cleanExit: Bool
    let lastEventName: String?
    let lastSequence: Int
    let processID: Int32
}

private struct DiagnosticWriteFailureEvent: Codable {
    let name: String
    let fields: [String: String]
}

private enum DiagnosticWriteError: Error, CustomStringConvertible {
    case createFailed(String)

    var description: String {
        switch self {
        case .createFailed(let path):
            return "Failed to create diagnostics log at \(path)"
        }
    }
}

/// Size-caps the diagnostics log by dropping the oldest lines. Extracted from `RememBarDiagnostics`
/// as a pure, stateless operation over (logURL, maxLogBytes, fileManager); behavior is identical to
/// the former `enforceRetention` instance method and it is still invoked under the diagnostics lock.
private enum DiagnosticLogRetention {
    static func enforce(logURL: URL, maxLogBytes: Int, fileManager: FileManager) throws {
        guard maxLogBytes > 0,
              fileManager.fileExists(atPath: logURL.path) else {
            return
        }
        // O(1) size probe first: a single search fires ~15-20 events, and re-reading the whole log
        // (up to maxLogBytes) on each one just to find it's under the cap is wasteful. Only read +
        // rewrite when actually over.
        let fileSize = ((try? fileManager.attributesOfItem(atPath: logURL.path))?[.size] as? NSNumber)?.intValue ?? 0
        guard fileSize > maxLogBytes else { return }
        let data = try Data(contentsOf: logURL)
        guard data.count > maxLogBytes else { return }
        guard let text = String(data: data, encoding: .utf8) else { return }

        var kept: [String] = []
        var keptBytes = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).reversed() {
            guard !line.isEmpty else { continue }
            let lineText = String(line)
            let lineBytes = lineText.utf8.count + 1
            if kept.isEmpty {
                kept.append(lineText)
                keptBytes += lineBytes
                continue
            }
            if keptBytes + lineBytes > maxLogBytes {
                break
            }
            kept.append(lineText)
            keptBytes += lineBytes
        }

        let retained = kept.reversed().joined(separator: "\n")
        try (retained + (retained.isEmpty ? "" : "\n")).write(to: logURL, atomically: true, encoding: .utf8)
    }
}
