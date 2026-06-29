@testable import BrowserMemoryBar
import AppKit
import Foundation
import SQLite3
import Testing

func setModificationDate(_ date: Date, for url: URL) throws {
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
}

struct ChromiumHistoryFixture {
    let title: String
    let url: String
    let visitTime: Int64
}

struct FirefoxHistoryFixture {
    let title: String
    let url: String
    let visitDate: Int64
}

func createChromiumHistory(at url: URL, title: String, url pageURL: String, visitTime: Int64) throws {
    try createChromiumHistory(
        at: url,
        rows: [ChromiumHistoryFixture(title: title, url: pageURL, visitTime: visitTime)]
    )
}

func createChromiumHistory(at url: URL, rows: [ChromiumHistoryFixture]) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK else {
        throw TestSQLiteError.open
    }
    defer { sqlite3_close(database) }

    let inserts = rows.enumerated().map { index, row in
        let id = index + 1
        let escapedTitle = row.title.replacingOccurrences(of: "'", with: "''")
        let escapedURL = row.url.replacingOccurrences(of: "'", with: "''")
        return """
        INSERT INTO urls VALUES(\(id), '\(escapedURL)', '\(escapedTitle)', 1);
        INSERT INTO visits VALUES(\(id), \(id), \(row.visitTime));
        """
    }.joined(separator: "\n")
    let sql = """
        CREATE TABLE urls(id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER);
        CREATE TABLE visits(id INTEGER PRIMARY KEY, url INTEGER, visit_time INTEGER);
        \(inserts)
        """
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
        throw TestSQLiteError.exec
    }
}

func createFirefoxHistory(at url: URL, rows: [FirefoxHistoryFixture]) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK else {
        throw TestSQLiteError.open
    }
    defer { sqlite3_close(database) }

    let inserts = rows.enumerated().map { index, row in
        let id = index + 1
        let escapedTitle = row.title.replacingOccurrences(of: "'", with: "''")
        let escapedURL = row.url.replacingOccurrences(of: "'", with: "''")
        return """
        INSERT INTO moz_places VALUES(\(id), '\(escapedURL)', '\(escapedTitle)');
        INSERT INTO moz_historyvisits VALUES(\(id), \(id), \(row.visitDate));
        """
    }.joined(separator: "\n")
    let sql = """
        CREATE TABLE moz_places(id INTEGER PRIMARY KEY, url TEXT, title TEXT);
        CREATE TABLE moz_historyvisits(id INTEGER PRIMARY KEY, place_id INTEGER, visit_date INTEGER);
        \(inserts)
        """
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
        throw TestSQLiteError.exec
    }
}

func createSafariHistory(at url: URL, title: String, url pageURL: String, visitTime: Double) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK else {
        throw TestSQLiteError.open
    }
    defer { sqlite3_close(database) }

    let escapedTitle = title.replacingOccurrences(of: "'", with: "''")
    let escapedURL = pageURL.replacingOccurrences(of: "'", with: "''")
    let sql = """
        CREATE TABLE history_items(id INTEGER PRIMARY KEY, url TEXT);
        CREATE TABLE history_visits(id INTEGER PRIMARY KEY, history_item INTEGER, visit_time REAL, title TEXT);
        INSERT INTO history_items VALUES(1, '\(escapedURL)');
        INSERT INTO history_visits VALUES(1, 1, \(visitTime), '\(escapedTitle)');
        """
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
        throw TestSQLiteError.exec
    }
}

enum TestSQLiteError: Error {
    case open
    case exec
}

final class ThreadRecordingSearchProvider: MemorySearching, @unchecked Sendable {
    private let lock = NSLock()
    private var _didRun = false
    private var _ranOnMainThread: Bool?

    var didRun: Bool {
        lock.withLock { _didRun }
    }

    var ranOnMainThread: Bool? {
        lock.withLock { _ranOnMainThread }
    }

    func searchResponse(query: String, refinements: [String], limit: Int) async -> MemorySearchResponse {
        lock.withLock {
            _didRun = true
            _ranOnMainThread = Thread.isMainThread
        }
        return MemorySearchResponse(results: [])
    }
}

struct RecordedSearchRequest: Equatable {
    let query: String
    let refinements: [String]
}

final class RequestRecordingSearchProvider: MemorySearching, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [RecordedSearchRequest] = []

    var requests: [RecordedSearchRequest] {
        lock.withLock { _requests }
    }

    func searchResponse(query: String, refinements: [String], limit: Int) async -> MemorySearchResponse {
        lock.withLock {
            _requests.append(RecordedSearchRequest(query: query, refinements: refinements))
        }
        return MemorySearchResponse(results: Array(MemoryResult.samples.values.prefix(limit)))
    }
}

struct StubSpotlightSearch: SpotlightSearching, Sendable {
    let urls: [URL]

    func search(query: String, root: URL) async throws -> [URL] {
        urls
    }
}

struct StubFileSearchAccessChecker: FileSearchAccessChecking {
    let issues: [FileSearchAccessIssue]

    func inaccessibleLocations(home: URL) -> [FileSearchAccessIssue] {
        issues
    }
}

struct ThrowingSpotlightSearch: SpotlightSearching, Sendable {
    func search(query: String, root: URL) async throws -> [URL] {
        throw TestSpotlightError.forcedFailure
    }
}

enum TestSpotlightError: Error, CustomStringConvertible {
    case forcedFailure

    var description: String {
        "forced spotlight failure"
    }
}

struct EmptyCrashReportScanner: RememBarCrashReportScanning {
    func reports(since: Date?, processID: Int32?) -> [RememBarCrashReportSummary] {
        []
    }
}

struct StaticMemorySearchProvider: MemorySearching, Sendable {
    let results: [MemoryResult]

    func searchResponse(query: String, refinements: [String], limit: Int) async -> MemorySearchResponse {
        MemorySearchResponse(results: Array(results.prefix(limit)))
    }
}

struct StaticResponseMemorySearchProvider: MemorySearching, Sendable {
    let response: MemorySearchResponse

    func searchResponse(query: String, refinements: [String], limit: Int) async -> MemorySearchResponse {
        MemorySearchResponse(
            results: Array(response.results.prefix(limit)),
            sourceStatuses: response.sourceStatuses
        )
    }
}

struct DelayedResponseMemorySearchProvider: MemorySearching, Sendable {
    let delay: Duration
    let response: MemorySearchResponse

    func searchResponse(query: String, refinements: [String], limit: Int) async -> MemorySearchResponse {
        try? await Task.sleep(for: delay)
        return MemorySearchResponse(
            results: Array(response.results.prefix(limit)),
            sourceStatuses: response.sourceStatuses
        )
    }
}

struct StubOnePasswordItemLister: OnePasswordItemListing {
    let result: Result<[OnePasswordItemSummary], OnePasswordItemListError>

    func listItems() async throws -> [OnePasswordItemSummary] {
        try result.get()
    }
}

struct ThrowingOnePasswordItemLister: OnePasswordItemListing {
    func listItems() async throws -> [OnePasswordItemSummary] {
        throw SensitiveOnePasswordError()
    }
}

struct CancellingOnePasswordItemLister: OnePasswordItemListing {
    func listItems() async throws -> [OnePasswordItemSummary] {
        throw CancellationError()
    }
}

struct SensitiveOnePasswordError: Error, CustomStringConvertible {
    static let secretText = "do-not-log-secret-recovery-code"

    var description: String {
        Self.secretText
    }
}

func writeExecutableShellScript(_ contents: String) throws -> URL {
    let url = try temporaryDirectory().appendingPathComponent("script.sh")
    try contents.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

func shellSingleQuoted(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}

@MainActor
final class RecordingMemoryResultOpener: MemoryResultOpening {
    private(set) var opened: [MemoryResult] = []

    func open(_ result: MemoryResult) {
        opened.append(result)
    }
}

func openFileDescriptorCount() throws -> Int {
    try FileManager.default.contentsOfDirectory(atPath: "/dev/fd")
        .filter { Int($0) != nil }
        .count
}

func createEmptyFile(at url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: url.path, contents: Data())
}

func createTextFile(at url: URL, contents: String) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try contents.write(to: url, atomically: true, encoding: .utf8)
}
