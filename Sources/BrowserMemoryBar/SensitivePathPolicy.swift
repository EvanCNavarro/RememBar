import Foundation

/// The single authority for deciding whether a file path is secret-bearing, and for
/// redacting such paths out of strings before they reach a log, diagnostic, or UI surface.
///
/// One core predicate — `isSensitiveLeaf(_:)` — backs two thin wrappers so there is never a
/// second, drifting copy of the rule:
///   - `isSensitive(_ url:)`   suppresses Quick Look thumbnail previews of secret files.
///   - `redactingSensitivePaths(in:)` scrubs path-bearing diagnostic fields and UI status text.
///
/// Matching is **leaf-only** (the last path component), case-insensitive: a benign file living
/// under an ancestor directory named `Secrets/` is never flagged. Redaction preserves the
/// directory context so diagnostics stay useful — only the sensitive leaf is replaced.
enum SensitivePathPolicy {
    static let redactionPlaceholder = "‹redacted›"

    /// Case-insensitive substrings that mark a file name as secret-bearing.
    /// Deliberately excludes bare `key` (too broad — would catch `monkey`); key material is
    /// matched by extension/exact-name instead.
    private static let nameKeywords: [String] = [
        "recovery", "password", "passphrase", "secret", "token",
        "seed", "mnemonic", "credential", "2fa", "otp",
        "backup code", "backup-code", "backupcode",
        "api key", "api-key", "apikey", "master-password", "private-key", "privatekey"
    ]

    /// Inherently secret-bearing file extensions (lower-cased).
    private static let sensitiveExtensions: Set<String> = [
        "pem", "key", "env", "kdbx", "p12", "pfx", "ppk", "jks",
        "keychain", "gpg", "asc", "pgp", "ovpn", "mobileconfig"
    ]

    /// Exact secret-bearing leaf names (lower-cased).
    private static let sensitiveExactLeaves: Set<String> = [
        "id_rsa", "id_ed25519", "id_ecdsa", "id_dsa",
        "wallet.dat", ".netrc", ".pgpass", "credentials"
    ]

    /// The core rule. Operates on a single path component (a file/dir name), never a full path.
    static func isSensitiveLeaf(_ leaf: String) -> Bool {
        let lower = leaf.lowercased()
        guard !lower.isEmpty else { return false }

        if sensitiveExactLeaves.contains(lower) { return true }

        // dotenv files: `.env`, `.env.local`, `.env.production`, …
        if lower == ".env" || lower.hasPrefix(".env.") { return true }

        let ext = (lower as NSString).pathExtension
        if !ext.isEmpty, sensitiveExtensions.contains(ext) { return true }

        return nameKeywords.contains { lower.contains($0) }
    }

    /// True when the URL's file name is secret-bearing. Used to suppress content previews.
    static func isSensitive(_ url: URL) -> Bool {
        isSensitiveLeaf(url.lastPathComponent)
    }

    /// Replaces the sensitive leaf inside any path-like token, keeping directory context.
    /// Tokenizes on the separators that appear in real diagnostic values — whitespace, `,`, `|`
    /// (handles the `file|/abs/path` identity form and comma-joined id lists) — and rebuilds the
    /// string with its original separators intact. Non-path and benign tokens pass through.
    static func redactingSensitivePaths(in value: String) -> String {
        // Space is intentionally NOT a separator — it is valid inside a filename
        // ("Backup Codes.txt"), and splitting on it would make this redactor's leaf
        // disagree with isSensitiveLeaf(url.lastPathComponent). Only structural
        // delimiters that join distinct values (`file|path,file|path`) split tokens.
        let separators: Set<Character> = ["\t", "\n", ",", "|"]
        var result = ""
        var token = ""
        for character in value {
            if separators.contains(character) {
                result += redactToken(token)
                token = ""
                result.append(character)
            } else {
                token.append(character)
            }
        }
        result += redactToken(token)
        return result
    }

    private static func redactToken(_ token: String) -> String {
        guard !token.isEmpty else { return token }

        guard token.contains("/") else {
            // A bare leaf with no directory, e.g. "recovery-codes.txt".
            return isSensitiveLeaf(token) ? redactionPlaceholder : token
        }

        let nsToken = token as NSString
        let leaf = nsToken.lastPathComponent
        guard isSensitiveLeaf(leaf) else { return token }

        let directory = nsToken.deletingLastPathComponent
        if directory.isEmpty { return redactionPlaceholder }
        if directory == "/" { return "/\(redactionPlaceholder)" }
        return "\(directory)/\(redactionPlaceholder)"
    }
}
