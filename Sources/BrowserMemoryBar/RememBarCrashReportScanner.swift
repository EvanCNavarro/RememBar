import Foundation

protocol RememBarCrashReportScanning: Sendable {
    func reports(since: Date?, processID: Int32?) -> [RememBarCrashReportSummary]
}

extension RememBarCrashReportScanning {
    func reports(since: Date?) -> [RememBarCrashReportSummary] {
        reports(since: since, processID: nil)
    }
}

struct RememBarCrashReportSummary: Equatable, Sendable {
    let url: URL
    let processName: String
    let processID: Int32?
    let incidentIdentifier: String?
    let identifier: String?
    let dateTime: String?
    let exceptionType: String?
    let terminationReason: String?
    let crashedThread: String?
    let topFrames: String

    var diagnosticFields: [String: String] {
        var fields = [
            "path": url.path,
            "filename": url.lastPathComponent,
            "processName": processName,
            "topFrames": topFrames
        ]
        if let processID { fields["crashProcessID"] = "\(processID)" }
        if let incidentIdentifier { fields["incidentIdentifier"] = incidentIdentifier }
        if let identifier { fields["identifier"] = identifier }
        if let dateTime { fields["dateTime"] = dateTime }
        if let exceptionType { fields["exceptionType"] = exceptionType }
        if let terminationReason { fields["terminationReason"] = terminationReason }
        if let crashedThread { fields["crashedThread"] = crashedThread }
        return fields
    }
}

struct RememBarCrashReportScanner: RememBarCrashReportScanning {
    private let directories: [URL]
    private let processNames: Set<String>

    init(
        directories: [URL] = RememBarCrashReportScanner.defaultDirectories(),
        processNames: Set<String> = ["RememBar", "BrowserMemoryBar"]
    ) {
        self.directories = directories
        self.processNames = processNames
    }

    func reports(since: Date?, processID: Int32?) -> [RememBarCrashReportSummary] {
        directories.flatMap { directory in
            reportURLs(in: directory, since: since)
        }
        .compactMap(parseReport)
        .filter { report in
            processNames.contains(report.processName) &&
                (processID == nil || report.processID == nil || report.processID == processID)
        }
        .sorted { lhs, rhs in
            lhs.url.lastPathComponent > rhs.url.lastPathComponent
        }
    }

    private func reportURLs(in directory: URL, since: Date?) -> [URL] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls.filter { url in
            let filename = url.lastPathComponent
            guard filename.hasSuffix(".crash") || filename.hasSuffix(".ips"),
                  processNames.contains(where: { filename.localizedCaseInsensitiveContains($0) }) else {
                return false
            }

            guard let since else { return true }
            let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            return modifiedAt >= since
        }
    }

    private func parseReport(_ url: URL) -> RememBarCrashReportSummary? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if url.pathExtension == "ips",
           let report = parseIPSCrashReport(data, url: url) {
            return report
        }

        guard let text = String(data: data, encoding: .utf8) else { return nil }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{"),
           let report = parseIPSCrashReport(data, url: url) {
            return report
        }

        return parseLegacyCrashReport(text, url: url)
    }

    private func parseIPSCrashReport(_ data: Data, url: URL) -> RememBarCrashReportSummary? {
        let objects = ipsJSONObjects(from: data)
        guard !objects.isEmpty else { return nil }

        let metadata = objects.first ?? [:]
        let report = objects.last ?? metadata
        guard let processName = stringValue(
            in: [report, metadata],
            keys: ["procName", "processName", "app_name", "name"]
        )
            ?? processNameFromFilename(url) else {
            return nil
        }

        let crashedThread = crashedThread(in: report)
        return RememBarCrashReportSummary(
            url: url,
            processName: processName,
            processID: int32Value(in: report, keys: ["pid", "processID"]),
            incidentIdentifier: stringValue(
                in: [report, metadata],
                keys: ["incident", "incidentIdentifier", "incident_id"]
            ),
            identifier: stringValue(in: [report, metadata], keys: ["bundleID", "bundleIdentifier", "identifier"]),
            dateTime: stringValue(in: [report, metadata], keys: ["captureTime", "dateTime", "timestamp"]),
            exceptionType: exceptionDescription(in: report),
            terminationReason: terminationDescription(in: report),
            crashedThread: crashedThread?.label,
            topFrames: topFrames(from: crashedThread?.frames ?? [])
        )
    }

    private func parseLegacyCrashReport(_ text: String, url: URL) -> RememBarCrashReportSummary? {
        let lines = text.components(separatedBy: .newlines)
        guard let processLine = value(for: "Process", in: lines),
              let processName = processLine.split(separator: " ").first.map(String.init) else {
            return nil
        }

        let crashedThread = value(for: "Crashed Thread", in: lines)
        return RememBarCrashReportSummary(
            url: url,
            processName: processName,
            processID: processID(fromProcessLine: processLine),
            incidentIdentifier: value(for: "Incident Identifier", in: lines),
            identifier: value(for: "Identifier", in: lines),
            dateTime: value(for: "Date/Time", in: lines),
            exceptionType: value(for: "Exception Type", in: lines),
            terminationReason: value(for: "Termination Reason", in: lines),
            crashedThread: crashedThread,
            topFrames: topFrames(from: lines, crashedThread: crashedThread)
        )
    }

    private func value(for prefix: String, in lines: [String]) -> String? {
        let marker = "\(prefix):"
        guard let line = lines.first(where: { $0.hasPrefix(marker) }) else { return nil }
        let value = line.dropFirst(marker.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func topFrames(from lines: [String], crashedThread: String?) -> String {
        let crashedThreadNumber = crashedThread?.split(separator: " ").first.map(String.init)
        let headerIndex = lines.firstIndex { line in
            if let crashedThreadNumber {
                return line.hasPrefix("Thread \(crashedThreadNumber) Crashed:")
            }
            return line.contains("Crashed:")
        }
        guard let headerIndex else { return "" }

        return lines
            .dropFirst(headerIndex + 1)
            .prefix { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .prefix(8)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: " | ")
    }

    private func ipsJSONObjects(from data: Data) -> [[String: Any]] {
        if let object = try? JSONSerialization.jsonObject(with: data),
           let report = object as? [String: Any] {
            return [report]
        }

        guard let text = String(data: data, encoding: .utf8),
              let newlineIndex = text.firstIndex(of: "\n") else {
            return []
        }

        let firstLine = String(text[..<newlineIndex])
        let rest = String(text[text.index(after: newlineIndex)...])
        return [firstLine, rest].compactMap { fragment in
            guard let fragmentData = fragment.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: fragmentData),
                  let report = object as? [String: Any] else {
                return nil
            }
            return report
        }
    }

    private func topFrames(from frames: [[String: Any]]) -> String {
        frames
            .prefix(8)
            .compactMap { frame in
                stringValue(in: frame, keys: ["symbol", "name", "function", "image"])
            }
            .joined(separator: " | ")
    }

    private func crashedThread(in report: [String: Any]) -> (label: String, frames: [[String: Any]])? {
        guard let threads = report["threads"] as? [[String: Any]] else { return nil }
        for (index, thread) in threads.enumerated() where boolValue(thread["triggered"]) == true {
            let label = stringValue(in: thread, keys: ["id", "threadId", "thread"])
                ?? "\(index)"
            return (label, thread["frames"] as? [[String: Any]] ?? [])
        }
        if let faultingThread = intValue(in: report, keys: ["faultingThread"]),
           threads.indices.contains(faultingThread) {
            let thread = threads[faultingThread]
            let label = stringValue(in: thread, keys: ["id", "threadId", "thread"])
                ?? "\(faultingThread)"
            return (label, thread["frames"] as? [[String: Any]] ?? [])
        }
        return nil
    }

    private func exceptionDescription(in report: [String: Any]) -> String? {
        if let value = stringValue(in: report, keys: ["exceptionType"]) {
            return value
        }
        guard let exception = dictionaryValue(in: report, keys: ["exception"]) else {
            return nil
        }
        return joinedDescription(from: [
            stringValue(in: exception, keys: ["type"]),
            stringValue(in: exception, keys: ["signal"]),
            stringValue(in: exception, keys: ["codes"])
        ])
    }

    private func terminationDescription(in report: [String: Any]) -> String? {
        if let value = stringValue(in: report, keys: ["terminationReason"]) {
            return value
        }
        guard let termination = dictionaryValue(in: report, keys: ["termination"]) else {
            return nil
        }
        let code = stringValue(in: termination, keys: ["code"]).map { "Code \($0)" }
        return joinedDescription(from: [
            stringValue(in: termination, keys: ["namespace"]),
            code,
            stringValue(in: termination, keys: ["reason"])
        ])
    }

    private func dictionaryValue(in dictionary: [String: Any], keys: [String]) -> [String: Any]? {
        for key in keys {
            if let value = dictionary[key] as? [String: Any] {
                return value
            }
        }
        return nil
    }

    private func stringValue(in dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let value = dictionary[key],
                  let rendered = scalarDescription(value) else {
                continue
            }
            return rendered
        }
        return nil
    }

    private func stringValue(in dictionaries: [[String: Any]], keys: [String]) -> String? {
        for dictionary in dictionaries {
            if let value = stringValue(in: dictionary, keys: keys) {
                return value
            }
        }
        return nil
    }

    private func intValue(in dictionary: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            switch dictionary[key] {
            case let int as Int:
                return int
            case let number as NSNumber:
                return number.intValue
            case let string as String:
                return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
            default:
                continue
            }
        }
        return nil
    }

    private func int32Value(in dictionary: [String: Any], keys: [String]) -> Int32? {
        guard let value = intValue(in: dictionary, keys: keys),
              value >= Int(Int32.min),
              value <= Int(Int32.max) else {
            return nil
        }
        return Int32(value)
    }

    private func processID(fromProcessLine line: String) -> Int32? {
        guard let start = line.lastIndex(of: "["),
              let end = line.lastIndex(of: "]"),
              start < end else {
            return nil
        }
        let text = line[line.index(after: start)..<end]
        guard let value = Int32(text) else { return nil }
        return value
    }

    private func scalarDescription(_ value: Any) -> String? {
        let rendered: String?
        switch value {
        case let string as String:
            rendered = string
        case let number as NSNumber:
            rendered = number.stringValue
        default:
            rendered = nil
        }
        let trimmed = rendered?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == true ? nil : trimmed
    }

    private func boolValue(_ value: Any?) -> Bool {
        switch value {
        case let bool as Bool:
            return bool
        case let number as NSNumber:
            return number.boolValue
        case let string as String:
            return string.caseInsensitiveCompare("true") == .orderedSame
        default:
            return false
        }
    }

    private func joinedDescription(from parts: [String?]) -> String? {
        let joined = parts
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }

    private func processNameFromFilename(_ url: URL) -> String? {
        let filename = url.deletingPathExtension().lastPathComponent
        return processNames.first { filename.localizedCaseInsensitiveContains($0) }
    }

    private static func defaultDirectories() -> [URL] {
        [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true),
            URL(fileURLWithPath: "/Library/Logs/DiagnosticReports", isDirectory: true)
        ]
    }
}
