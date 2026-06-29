import Foundation
import Testing
@testable import BrowserMemoryBar

/// Regression coverage for the HIGH-severity secret-leak fix:
///   - Vector B: Quick Look must not render content previews of secret files.
///   - Vector A: diagnostics must not persist raw secret-file paths.
///   - UI source-status detail must not surface raw secret paths.
@Suite("SecretLeakRegression")
struct SecretLeakRegressionTests {
    // MARK: Vector B — thumbnail suppression at the identity authority

    @Test("file result for a secret-bearing name yields no content preview")
    func secretFileHasNoPreviewThumbnail() {
        let secret = MemoryResult(
            fileURL: URL(fileURLWithPath: "/Users/x/Downloads/github-recovery-codes.txt"),
            displayPath: "Downloads/github-recovery-codes.txt",
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_000),
            rank: 100
        )
        // Suppressed → falls back to the extension tile, never Quick Look.
        #expect(secret.thumbnail == nil)
    }

    @Test("file result for an ordinary name still gets a Quick Look preview")
    func ordinaryFileKeepsPreviewThumbnail() {
        let url = URL(fileURLWithPath: "/Users/x/Documents/alpha-soccer-card.psd")
        let ordinary = MemoryResult(
            fileURL: url,
            displayPath: "Documents/alpha-soccer-card.psd",
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_000),
            rank: 100
        )
        #expect(ordinary.thumbnail == .filePreview(url))
    }

    // MARK: Vector A — diagnostics must not persist raw secret paths (key-scoped)

    @Test("diagnostics redact secret-file paths from path-bearing fields only")
    func diagnosticsRedactSensitivePathFields() throws {
        let directory = try temporaryDirectory().appendingPathComponent("Diagnostics", isDirectory: true)
        let diagnostics = RememBarDiagnostics(
            directory: directory,
            sessionID: "leak",
            now: IncrementingClock(start: Date(timeIntervalSince1970: 1_800_000_000)).nextDate,
            processID: 999
        )
        _ = diagnostics.startSession()
        diagnostics.record(
            "test.path.event",
            fields: [
                "path": "/Users/x/Downloads/github-recovery-codes.txt",
                "topResultIDs": "file|/a/normal.txt,file|/b/recovery-codes.txt",
                "query": "facebook recovery codes"   // non-path key: must pass through verbatim
            ]
        )

        let events = try diagnosticEvents(at: diagnostics.logURL)
        let event = try #require(events.first { $0.name == "test.path.event" })

        // Vector A closed: raw secret leaf gone, directory context kept for debugging.
        #expect(event.fields["path"]?.contains("github-recovery-codes.txt") == false)
        #expect(event.fields["path"]?.hasPrefix("/Users/x/Downloads/") == true)
        // Selective within a comma/pipe-joined id list.
        #expect(event.fields["topResultIDs"]?.contains("recovery-codes.txt") == false)
        #expect(event.fields["topResultIDs"]?.contains("normal.txt") == true)
        // Key-scope honored: a user's search text is never mangled.
        #expect(event.fields["query"] == "facebook recovery codes")
    }

    // MARK: UI source-status detail must not surface raw secret paths

    @Test("searched-state display detail redacts a secret path leaf")
    func searchedStatusDisplayDetailRedactsSecretPath() {
        let status = MemorySearchSourceStatus(
            id: "files.spotlight",
            sourceName: "Files",
            state: .searched,
            detail: "Matched /Users/x/Downloads/github-recovery-codes.txt"
        )
        #expect(status.displayDetail.contains("github-recovery-codes.txt") == false)
        #expect(status.accessibilityDetail.contains("github-recovery-codes.txt") == false)
    }

    // MARK: a file result's diagnostic `title` (the bare filename) must be redacted

    @Test("file diagnostic title redacts a secret filename but keeps ordinary ones")
    func fileDiagnosticTitleRedacted() {
        let secret = MemoryResult(
            fileURL: URL(fileURLWithPath: "/Users/x/Downloads/github-recovery-codes.txt"),
            displayPath: "Downloads/github-recovery-codes.txt",
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_000),
            rank: 100
        )
        #expect(secret.diagnosticFields["title"]?.contains("github-recovery-codes.txt") == false)

        let ordinary = MemoryResult(
            fileURL: URL(fileURLWithPath: "/Users/x/Documents/report.pdf"),
            displayPath: "Documents/report.pdf",
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_000),
            rank: 100
        )
        #expect(ordinary.diagnosticFields["title"] == "report.pdf")
    }
}
