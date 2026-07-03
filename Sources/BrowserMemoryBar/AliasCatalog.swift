import Foundation

/// The single live authority for the user's term families at runtime — the reloadable counterpart to
/// the immutable `AliasGroups` value.
///
/// Deliberately **NOT** `@MainActor`. Search providers read the current families from
/// `CompositeMemorySearchProvider`'s `withTaskGroup`, which runs OFF the main actor; a main-actor
/// catalog would be a Swift-6 cross-actor isolation error there (and crash under `assumeIsolated`).
/// Instead this is a lock-guarded `@unchecked Sendable` reference type: `snapshot` is a thread-safe
/// synchronous read callable from any actor, and `update(_:)` is the single writer (sanitize →
/// atomic save → swap in memory). The SwiftUI editor drives a separate `@MainActor` view-model that
/// writes THROUGH this catalog; it never tries to make the shared catalog itself main-isolated.
///
/// Liveness: because providers read `snapshot` per search (reference semantics), an in-app edit is
/// visible on the very next search — no app restart, no provider rebuild.
final class AliasCatalog: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var groups: AliasGroups
    private let diagnostics: RememBarDiagnostics

    init(url: URL = RememBarPaths.current.aliasesURL, diagnostics: RememBarDiagnostics = .shared) {
        self.url = url
        self.diagnostics = diagnostics
        self.groups = AliasGroups.load(from: url)
    }

    /// The current families — a `Sendable` value, safe to read from any actor/thread.
    var snapshot: AliasGroups {
        lock.lock()
        defer { lock.unlock() }
        return groups
    }

    /// Replace the families from an editor's draft: sanitize (via `AliasGroups.init`), persist
    /// atomically, then publish in memory. A failed write is recorded but never throws into the UI —
    /// the in-memory value still updates so the session reflects the edit.
    func update(families: [[String]]) {
        let sanitized = AliasGroups(groups: families)
        do {
            try sanitized.save(to: url)
        } catch {
            diagnostics.record(
                RememBarDiagnosticEvent.aliasCatalogSaveFailed,
                level: .error,
                fields: ["errorType": String(reflecting: type(of: error))]
            )
        }
        lock.lock()
        groups = sanitized
        lock.unlock()
        diagnostics.record(
            RememBarDiagnosticEvent.aliasCatalogUpdated,
            fields: ["groupCount": "\(sanitized.families.count)"]
        )
    }

    /// Re-read the file (e.g. after an external hand-edit) and publish it in memory.
    func reload() {
        let loaded = AliasGroups.load(from: url)
        lock.lock()
        groups = loaded
        lock.unlock()
        diagnostics.record(
            RememBarDiagnosticEvent.aliasCatalogReloaded,
            fields: ["groupCount": "\(loaded.families.count)"]
        )
    }
}
