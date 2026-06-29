import Foundation
import SQLite3

struct HistoryDatabaseReader {
    private static let rowLimit = 50_000

    let source: HistorySource
    let since: Date?

    func readRows() throws -> [HistoryItem] {
        try SQLiteSnapshot.withSnapshot(of: source.url, fileManager: .default) { snapshot in
            let database = try SQLiteDatabase(url: snapshot)
            defer { database.close() }
            return try queryRows(database)
        }
    }

    private func queryRows(_ database: SQLiteDatabase) throws -> [HistoryItem] {
        let sql: String
        let visitedAt: (SQLiteStatement) -> Date

        switch source.family {
        case .chromium:
            let sinceClause = since.map { "WHERE v.visit_time >= \(HistoryDate.chromiumTimestamp($0))" } ?? ""
            sql = """
                SELECT v.visit_time, COALESCE(u.title, ''), u.url
                FROM visits v JOIN urls u ON u.id = v.url
                \(sinceClause)
                ORDER BY v.visit_time DESC
                LIMIT \(Self.rowLimit)
                """
            visitedAt = { HistoryDate.chromium($0.int64(at: 0)) }
        case .firefox:
            let sinceClause = since.map { "WHERE v.visit_date >= \(HistoryDate.firefoxTimestamp($0))" } ?? ""
            sql = """
                SELECT v.visit_date, COALESCE(p.title, ''), p.url
                FROM moz_historyvisits v JOIN moz_places p ON p.id = v.place_id
                \(sinceClause)
                ORDER BY v.visit_date DESC
                LIMIT \(Self.rowLimit)
                """
            visitedAt = { HistoryDate.firefox($0.int64(at: 0)) }
        case .safari:
            let sinceClause = since.map { "WHERE v.visit_time >= \(HistoryDate.safariTimestamp($0))" } ?? ""
            sql = """
                SELECT v.visit_time, COALESCE(v.title, ''), i.url
                FROM history_visits v JOIN history_items i ON i.id = v.history_item
                \(sinceClause)
                ORDER BY v.visit_time DESC
                LIMIT \(Self.rowLimit)
                """
            visitedAt = { HistoryDate.safari($0.double(at: 0)) }
        }

        return try database.query(sql) { statement in
            guard let url = URL(string: statement.text(at: 2)), WorkspaceBrowserOpener.canOpen(url) else {
                return nil
            }
            let visitedAtDate = visitedAt(statement)
            if let since, visitedAtDate < since {
                return nil
            }
            return HistoryItem(
                browser: source.browser,
                profile: source.profile,
                visitedAt: visitedAtDate,
                title: statement.text(at: 1),
                url: url,
                sourcePath: source.url.path
            )
        }
    }
}

private enum SQLiteSnapshot {
    static func withSnapshot<T>(of source: URL, fileManager: FileManager, body: (URL) throws -> T) throws -> T {
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("remembar-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let snapshot = temporaryDirectory.appendingPathComponent(source.lastPathComponent)
        try fileManager.copyItem(at: source, to: snapshot)
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: "\(source.path)\(suffix)")
            if fileManager.fileExists(atPath: sidecar.path) {
                try fileManager.copyItem(at: sidecar, to: URL(fileURLWithPath: "\(snapshot.path)\(suffix)"))
            }
        }
        return try body(snapshot)
    }
}

private final class SQLiteDatabase {
    private var handle: OpaquePointer?

    init(url: URL) throws {
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        let uri = "file:\(url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path)?mode=ro"
        guard sqlite3_open_v2(uri, &handle, flags, nil) == SQLITE_OK else {
            throw SQLiteError.open(message: String(cString: sqlite3_errmsg(handle)))
        }
    }

    func close() {
        if handle != nil {
            sqlite3_close(handle)
            handle = nil
        }
    }

    func query<T>(_ sql: String, row: (SQLiteStatement) throws -> T?) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.prepare(message: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }

        var rows: [T] = []
        while true {
            let result = sqlite3_step(statement)
            switch result {
            case SQLITE_ROW:
                if let item = try row(SQLiteStatement(statement: statement)) {
                    rows.append(item)
                }
            case SQLITE_DONE:
                return rows
            default:
                throw SQLiteError.step(message: String(cString: sqlite3_errmsg(handle)))
            }
        }
    }
}

private struct SQLiteStatement {
    let statement: OpaquePointer?

    func int64(at index: Int32) -> Int64 {
        sqlite3_column_int64(statement, index)
    }

    func double(at index: Int32) -> Double {
        sqlite3_column_double(statement, index)
    }

    func text(at index: Int32) -> String {
        guard let text = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: text)
    }
}

enum SQLiteError: Error, CustomStringConvertible {
    case open(message: String)
    case prepare(message: String)
    case step(message: String)

    var description: String {
        switch self {
        case .open(let message):
            return "SQLite open failed: \(message)"
        case .prepare(let message):
            return "SQLite prepare failed: \(message)"
        case .step(let message):
            return "SQLite step failed: \(message)"
        }
    }
}
