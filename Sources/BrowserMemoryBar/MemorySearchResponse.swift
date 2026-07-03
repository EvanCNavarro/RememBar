import Foundation

struct MemorySearchResponse: Equatable, Sendable {
    let results: [MemoryResult]
    let sourceStatuses: [MemorySearchSourceStatus]

    init(results: [MemoryResult] = [], sourceStatuses: [MemorySearchSourceStatus] = []) {
        self.results = results
        self.sourceStatuses = sourceStatuses
    }
}

struct MemorySearchSourceStatus: Identifiable, Equatable, Sendable {
    enum State: String, Equatable, Sendable {
        case searched
        case blocked
        case unavailable
        case failed
        case skipped
    }

    let id: String
    let sourceName: String
    let state: State
    let detail: String

    var displayDetail: String {
        switch state {
        case .searched, .skipped:
            return SensitivePathPolicy.redactingSensitivePaths(in: detail)
        case .blocked:
            // A blocked password manager isn't a macOS permission — it's the manager's own lock /
            // sign-in / CLI-integration state. Show its own (fixed, path-free) guidance verbatim; do
            // NOT run it through the path redactor, which would nuke the literal word "password".
            return isPasswordManager ? detail : "Permission required"
        case .unavailable:
            return detail.contains("/")
                ? "Source is unavailable"
                : SensitivePathPolicy.redactingSensitivePaths(in: detail)
        case .failed:
            return "Could not read this source"
        }
    }

    var accessibilityDetail: String {
        displayDetail
    }

    var stateLabel: String {
        switch state {
        case .searched:
            return "Searched"
        case .blocked:
            return "Blocked"
        case .unavailable:
            return "Unavailable"
        case .failed:
            return "Failed"
        case .skipped:
            return "Skipped"
        }
    }

    var systemImageName: String {
        switch state {
        case .searched:
            return "checkmark.circle"
        case .blocked:
            return "lock.trianglebadge.exclamationmark"
        case .unavailable:
            return "questionmark.circle"
        case .failed:
            return "exclamationmark.triangle"
        case .skipped:
            return "minus.circle"
        }
    }
}

/// How a source state is surfaced in the panel. The single authority — the view never
/// re-derives this with scattered `state == .blocked` checks.
enum SourceStatusCategory: Equatable, Sendable {
    case informational   // folds into the one-line summary
    case exception       // promoted to its own row (worth the user's attention)
}

extension MemorySearchSourceStatus.State {
    var category: SourceStatusCategory {
        switch self {
        // `.unavailable` = source not set up / nothing to search (CLI absent, no data). Benign
        // context, not a user-actionable problem → folds into the summary. Only permission
        // (`.blocked`) and genuine read errors (`.failed`) are worth promoting.
        case .searched, .skipped, .unavailable:
            return .informational
        case .blocked, .failed:
            return .exception
        }
    }
}

extension MemorySearchSourceStatus {
    var isException: Bool { state.category == .exception }
}

/// What the user can DO about a problem source. The single authority — the view renders a button
/// from this and the store dispatches on it; neither re-derives the mapping.
enum SourceRemediation: Equatable, Sendable {
    case grantFullDiskAccess       // open Settings → Privacy → Full Disk Access (e.g. Safari history)
    case enablePasswordManagerCLI  // open the password manager's CLI setup docs (its own auth, not TCC)
    case retrySearch               // re-run the current query (e.g. a transient file-search failure)

    var actionLabel: String {
        switch self {
        case .grantFullDiskAccess: return "Grant access"
        case .enablePasswordManagerCLI: return "How to enable"
        case .retrySearch: return "Retry"
        }
    }
}

extension MemorySearchSourceStatus {
    /// Source id for the 1Password provider — shared so the provider and the remediation mapping
    /// can't drift. It's the one blocked source that is NOT a macOS TCC permission.
    static let onePasswordID = "1password"

    /// A password manager is reached through its own CLI (`op`), so a "blocked" state means the
    /// manager is locked / signed out / has CLI integration off — none of which Full Disk Access
    /// can fix. Keyed on the stable source id the provider sets.
    var isPasswordManager: Bool { id == Self.onePasswordID }

    /// The action offered for this source, or nil when there is nothing to act on.
    var remediation: SourceRemediation? {
        switch state {
        // Route password-manager blocks to CLI setup guidance, not Full Disk Access — sending the
        // user to a macOS permission pane for a 1Password sign-in problem is a category error.
        case .blocked: return isPasswordManager ? .enablePasswordManagerCLI : .grantFullDiskAccess
        case .failed: return .retrySearch
        case .searched, .skipped, .unavailable: return nil
        }
    }
}
