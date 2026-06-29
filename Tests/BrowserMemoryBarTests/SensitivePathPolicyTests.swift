import Foundation
import Testing
@testable import BrowserMemoryBar

@Suite("SensitivePathPolicy")
struct SensitivePathPolicyTests {
    // MARK: isSensitive(URL) — leaf-only classification

    @Test("classifies secret-bearing file names as sensitive")
    func classifiesSecretNames() {
        let sensitive = [
            "/Users/x/Downloads/github-recovery-codes.txt",
            "/Users/x/Downloads/github-recovery-codes-inv.txt",
            "/Users/x/MyPassword.txt",        // case-insensitive keyword
            "/Users/x/seed phrase.rtf",       // space variant
            "/Users/x/2fa-backup.txt",
            "/Users/x/.ssh/id_rsa",
            "/Users/x/.ssh/id_ed25519",
            "/Users/x/vault.kdbx",            // keystore extension
            "/Users/x/cert.pem",
            "/Users/x/key.p12",
            "/Users/x/config.env",            // .env via real extension
            "/Users/x/project/.env",          // dotenv leaf
            "/Users/x/wallet.dat"
        ]
        for path in sensitive {
            #expect(SensitivePathPolicy.isSensitive(URL(fileURLWithPath: path)) == true,
                    "expected sensitive: \(path)")
        }
    }

    @Test("classifies ordinary file names as not sensitive")
    func classifiesOrdinaryNames() {
        let ordinary = [
            "/Users/x/Downloads/vacation.png",
            "/Users/x/alpha-soccer-card.psd",
            "/Users/x/notes.txt",
            "/Users/x/report.pdf",
            "/Users/x/monkey.txt"             // 'key' must NOT match as a name keyword
        ]
        for path in ordinary {
            #expect(SensitivePathPolicy.isSensitive(URL(fileURLWithPath: path)) == false,
                    "expected NOT sensitive: \(path)")
        }
    }

    @Test("matches only the leaf, never an ancestor directory")
    func matchesLeafNotAncestor() {
        // A benign file living under a folder literally named "Secrets" must NOT be flagged.
        let url = URL(fileURLWithPath: "/Users/x/Secrets/vacation.png")
        #expect(SensitivePathPolicy.isSensitive(url) == false)
    }

    // MARK: redactingSensitivePaths(in:) — string scrub for logs/UI

    @Test("redacts a sensitive leaf while preserving its directory context")
    func redactsLeafKeepsDirectory() {
        let out = SensitivePathPolicy.redactingSensitivePaths(
            in: "/Users/x/Downloads/github-recovery-codes.txt")
        #expect(out.contains("github-recovery-codes.txt") == false)
        #expect(out.hasPrefix("/Users/x/Downloads/"))   // directory preserved for debugging
    }

    @Test("redacts the file| identity form and comma-joined id lists selectively")
    func redactsIdentityAndLists() {
        let out = SensitivePathPolicy.redactingSensitivePaths(
            in: "file|/a/normal.txt,file|/b/recovery-codes.txt")
        #expect(out.contains("recovery-codes.txt") == false) // sensitive id redacted
        #expect(out.contains("normal.txt") == true)          // benign id preserved
    }

    @Test("leaves non-path strings untouched")
    func leavesNonPathsUntouched() {
        #expect(SensitivePathPolicy.redactingSensitivePaths(in: "12 results") == "12 results")
        #expect(SensitivePathPolicy.redactingSensitivePaths(in: "Authorization denied") == "Authorization denied")
    }

    @Test("redacts a bare sensitive leaf with no directory")
    func redactsBareLeaf() {
        let out = SensitivePathPolicy.redactingSensitivePaths(in: "recovery-codes.txt")
        #expect(out.contains("recovery-codes.txt") == false)
    }

    @Test("redacts sensitive leaves containing spaces (renamed secret files)")
    func redactsSpaceContainingSecretLeaves() {
        // The redactor's leaf must equal isSensitive(URL)'s leaf even when the filename
        // contains spaces — otherwise a renamed "Backup Codes.txt" leaks. (reviewer B1)
        let inList = SensitivePathPolicy.redactingSensitivePaths(
            in: "file|/a/normal.txt,file|/Users/x/Downloads/Backup Codes.txt")
        #expect(inList.contains("Backup Codes.txt") == false)
        #expect(inList.contains("normal.txt") == true)

        let inDetail = SensitivePathPolicy.redactingSensitivePaths(
            in: "Matched /Users/x/My Recovery Codes.txt")
        #expect(inDetail.contains("Codes.txt") == false)
        #expect(inDetail.hasPrefix("Matched /Users/x/"))
    }
}
