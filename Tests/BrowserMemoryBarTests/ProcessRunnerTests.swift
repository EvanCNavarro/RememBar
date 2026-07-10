@testable import BrowserMemoryBar
import Foundation
import Testing

/// Direct tests of the shared CLI-process primitive's drain-completion contract: a successful result
/// means the process exited AND its output drained to EOF. If a descendant inherits + holds the stdout
/// write end open past the grace, the primitive must FAIL LOUD (`.drainIncomplete`) — NOT silently
/// return the empty capture as success (which a search would read as a bogus "0 results").
struct ProcessRunnerTests {
    @Test("fails loud with .drainIncomplete when a descendant holds stdout past the grace")
    func drainIncompleteWhenDescendantHoldsStdoutOpen() throws {
        // The shell writes output then backgrounds a subprocess that inherits stdout and outlives it —
        // the pipe write end stays open, so `readDataToEndOfFile` can't reach EOF. Tiny injected grace
        // (< the descendant's lifetime) so the test is fast + deterministic; production's default is generous.
        let scriptURL = try writeExecutableShellScript("""
        #!/bin/sh
        printf 'the real output'
        sleep 1 &
        """)
        // Assert the SPECIFIC case — this test is the sole guard on the fix's reason for existing, so a
        // regression that threw a different ProcessRunError (or a real .timedOut) must NOT pass green.
        do {
            _ = try ProcessRunner.run(
                executableURL: scriptURL,
                arguments: [],
                timeout: .seconds(30),
                state: RunningProcessState(),
                separateStderr: false,
                drainGrace: .milliseconds(200)
            )
            Issue.record("expected .drainIncomplete, but no error was thrown (silent empty capture)")
        } catch ProcessRunError.drainIncomplete {
            // pass
        } catch {
            Issue.record("expected .drainIncomplete, got \(error)")
        }
    }
}
