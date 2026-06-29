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
            return "Permission required"
        case .unavailable:
            return detail.contains("/") ? "Source is unavailable" : SensitivePathPolicy.redactingSensitivePaths(in: detail)
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
    case grantFullDiskAccess   // open Settings → Privacy → Full Disk Access (e.g. Safari history)
    case retrySearch           // re-run the current query (e.g. a transient file-search failure)

    var actionLabel: String {
        switch self {
        case .grantFullDiskAccess: return "Grant access"
        case .retrySearch: return "Retry"
        }
    }
}

extension MemorySearchSourceStatus {
    /// The action offered for this source, or nil when there is nothing to act on.
    var remediation: SourceRemediation? {
        switch state {
        case .blocked: return .grantFullDiskAccess
        case .failed: return .retrySearch
        case .searched, .skipped, .unavailable: return nil
        }
    }
}

