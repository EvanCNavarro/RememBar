@testable import BrowserMemoryBar
import Foundation
import Testing

@Suite("SourceStatus")
struct SourceStatusTests {
    private func status(_ name: String, _ state: MemorySearchSourceStatus.State) -> MemorySearchSourceStatus {
        MemorySearchSourceStatus(id: name, sourceName: name, state: state, detail: "")
    }

    // MARK: category — only actionable problems are exceptions (the panel stays quiet otherwise)

    @Test("only blocked/failed are exceptions; searched/skipped/unavailable are informational")
    func categoryMapping() {
        #expect(MemorySearchSourceStatus.State.searched.category == .informational)
        #expect(MemorySearchSourceStatus.State.skipped.category == .informational)
        #expect(MemorySearchSourceStatus.State.unavailable.category == .informational)
        #expect(MemorySearchSourceStatus.State.blocked.category == .exception)
        #expect(MemorySearchSourceStatus.State.failed.category == .exception)
        #expect(status("Files", .failed).isException == true)
        #expect(status("Chrome", .searched).isException == false)
    }

    // MARK: remediation — the single authority for what an exception can DO

    @Test("blocked offers grant-access; failed offers retry; non-exceptions offer nothing")
    func remediationMapping() {
        #expect(status("Safari", .blocked).remediation == .grantFullDiskAccess)
        // A blocked password manager is its own CLI auth, NOT a macOS permission — so it must offer
        // CLI setup guidance, never Full Disk Access. Keyed on the real source id ("1password").
        #expect(status(MemorySearchSourceStatus.onePasswordID, .blocked).remediation == .enablePasswordManagerCLI)
        #expect(status("Files", .failed).remediation == .retrySearch)
        #expect(status("Chrome", .searched).remediation == nil)
        #expect(status(MemorySearchSourceStatus.onePasswordID, .unavailable).remediation == nil)
        #expect(status("x", .skipped).remediation == nil)
        #expect(SourceRemediation.grantFullDiskAccess.actionLabel == "Grant access")
        #expect(SourceRemediation.enablePasswordManagerCLI.actionLabel == "How to enable")
        #expect(SourceRemediation.retrySearch.actionLabel == "Retry")
    }
}
