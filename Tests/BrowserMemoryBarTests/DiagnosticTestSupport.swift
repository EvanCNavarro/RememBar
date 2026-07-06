import Foundation
import Testing

struct DecodedDiagnosticEvent: @unchecked Sendable {
    let raw: [String: Any]

    var name: String {
        raw["name"] as? String ?? ""
    }

    var sequence: Int {
        raw["sequence"] as? Int ?? -1
    }

    var sessionID: String {
        raw["sessionID"] as? String ?? ""
    }

    var file: String {
        raw["file"] as? String ?? ""
    }

    var line: Int {
        raw["line"] as? Int ?? -1
    }

    var fields: [String: String] {
        raw["fields"] as? [String: String] ?? [:]
    }
}

func diagnosticEvents(at url: URL) throws -> [DecodedDiagnosticEvent] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    return try String(contentsOf: url, encoding: .utf8)
        .split(separator: "\n")
        .map { line in
            let data = try #require(String(line).data(using: .utf8))
            let json = try JSONSerialization.jsonObject(with: data)
            let object = try #require(json as? [String: Any])
            return DecodedDiagnosticEvent(raw: object)
        }
}

func diagnosticState(at url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    let json = try JSONSerialization.jsonObject(with: data)
    return try #require(json as? [String: Any])
}

func eventuallyDiagnosticEvents(
    at url: URL,
    prefix: String,
    count expectedCount: Int,
    // 200 × 20ms = a 4s budget. Polling returns as soon as the events land, so a big budget costs the
    // happy path nothing — it only prevents a false-fail when a loaded machine (e.g. the app running
    // alongside, or a concurrent build) starves the async work past a tighter window.
    attempts: Int = 200
) async -> [DecodedDiagnosticEvent] {
    var latest: [DecodedDiagnosticEvent] = []
    for _ in 0..<attempts {
        latest = ((try? diagnosticEvents(at: url)) ?? [])
            .filter { $0.name.hasPrefix(prefix) }
        if latest.count == expectedCount {
            return latest
        }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return latest
}

/// Polls `condition` until it's true or the budget runs out. The budget is DELIBERATELY generous
/// (200 × 50ms = 10s) because it's a false-fail ceiling, NOT an asserted latency: the loop returns the
/// instant the condition holds (~one tick on an idle machine), so a large ceiling costs the happy path
/// nothing while preventing a flake when a loaded machine — the app running alongside, a concurrent
/// build — starves the async work past a tighter window. (The reproduced flake: `rapidTypingCoalesces`
/// exceeded the old 2.5s ceiling with RememBar live.) A genuine hang still fails, just at 10s.
func eventually(
    attempts: Int = 200,
    interval: Duration = .milliseconds(50),
    _ condition: @escaping () async -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if await condition() {
            return true
        }
        try? await Task.sleep(for: interval)
    }
    return false
}

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("remembar-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

final class IncrementingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var timestamp: TimeInterval

    init(start: Date) {
        self.timestamp = start.timeIntervalSince1970
    }

    func nextDate() -> Date {
        lock.withLock {
            let date = Date(timeIntervalSince1970: timestamp)
            timestamp += 1
            return date
        }
    }
}
