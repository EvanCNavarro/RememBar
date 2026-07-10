import Foundation

struct ProcessRunResult {
    let processID: Int32
    let terminationStatus: Int32
    let stdout: Data
    let stderr: Data // empty when stderr is merged into stdout (separateStderr == false)
}

enum ProcessRunError: Error {
    case cancelledBeforeLaunch
    case launchFailed(Error)
    case cancelledAfterLaunch(processID: Int32)
    case timedOut(processID: Int32)
    /// The process exited but its output couldn't be drained to EOF within `drainGrace` — a surviving
    /// descendant inherited and is holding the stdout/stderr write end open. We fail loud rather than
    /// return the (empty) partial capture as success: for a search primitive, "couldn't finish reading"
    /// must surface as an error, not a silent "0 results".
    case drainIncomplete(processID: Int32)
}

/// The single CLI-process primitive. Spawns a process, drains its output, enforces a timeout, and
/// honors cooperative cancellation via `RunningProcessState` — the error-prone orchestration
/// (semaphore / timeout / terminate ordering, 1-or-2-pipe draining) shared by every CLI search
/// provider. Telemetry and error mapping are the caller's job and are injected via the callbacks /
/// typed throws; this type owns only the mechanics so there is exactly one place to get them right.
enum ProcessRunner {
    /// Bundles the pipe/sink/semaphore triple(s) for stdout and (optionally) stderr, so the drain
    /// helpers take one value instead of six-plus loose parameters. When `separateStderr` is false
    /// the err members mirror the out pipe and `errDone` is nil, exactly as the inline code did.
    private struct Drainers {
        let outPipe: Pipe
        let outData: LockedData
        let outDone: DispatchSemaphore
        let errPipe: Pipe
        let errData: LockedData
        let errDone: DispatchSemaphore?
        let separateStderr: Bool
    }

    static func run(
        executableURL: URL,
        arguments: [String],
        timeout: DispatchTimeInterval,
        state: RunningProcessState,
        separateStderr: Bool,
        // How long to wait for the output drainers to reach EOF AFTER the process exits. Normally a
        // formality (the reader signals in ms); generous by default so load-starvation can't false-fire.
        // A lapse means a descendant is holding the pipe open → `.drainIncomplete`. Injectable for tests.
        drainGrace: DispatchTimeInterval = .seconds(5),
        onWillLaunch: () -> Void = {},
        onLaunched: (Int32) -> Void = { _ in },
        onCancelRequestedAfterLaunch: (Int32) -> Void = { _ in }
    ) throws -> ProcessRunResult {
        try Task.checkCancellation()

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = separateStderr ? Pipe() : outPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        let finished = DispatchSemaphore(value: 0)
        let drainers = Drainers(
            outPipe: outPipe,
            outData: LockedData(),
            outDone: DispatchSemaphore(value: 0),
            errPipe: errPipe,
            errData: LockedData(),
            errDone: separateStderr ? DispatchSemaphore(value: 0) : nil,
            separateStderr: separateStderr
        )
        process.terminationHandler = { _ in finished.signal() }

        if state.isCancelled { throw ProcessRunError.cancelledBeforeLaunch }
        onWillLaunch()
        do {
            try process.run()
        } catch {
            throw ProcessRunError.launchFailed(error)
        }
        state.attachLaunched(process)
        let pid = process.processIdentifier
        onLaunched(pid)

        spawnDrainers(drainers)

        if state.isCancelled, process.isRunning {
            onCancelRequestedAfterLaunch(pid)
            process.terminate()
        }

        guard finished.wait(timeout: .now() + timeout) == .success else {
            try failTimedOut(process: process, finished: finished, drainers: drainers, pid: pid)
        }

        // Require the drainers to reach EOF (fully captured) before reporting success. A lapse means a
        // surviving descendant holds the write end open — fail loud rather than return the empty capture
        // as success. We do NOT close the read handle to force it: closing an fd whose background reader
        // is blocked in `readDataToEndOfFile` is undocumented on Darwin (can hang or raise an uncaught
        // exception in the GCD block). The blocked reader self-cleans when the descendant exits.
        guard drainers.outDone.wait(timeout: .now() + drainGrace) == .success else {
            throw ProcessRunError.drainIncomplete(processID: pid)
        }
        if let errDone = drainers.errDone, errDone.wait(timeout: .now() + drainGrace) != .success {
            throw ProcessRunError.drainIncomplete(processID: pid)
        }

        if state.isCancelled { throw ProcessRunError.cancelledAfterLaunch(processID: pid) }

        return ProcessRunResult(
            processID: pid,
            terminationStatus: process.terminationStatus,
            stdout: drainers.outData.get(),
            stderr: separateStderr ? drainers.errData.get() : Data()
        )
    }

    /// Spawns the background reader(s) that drain the pipe(s) to EOF. Identical to the inline
    /// `DispatchQueue.global(qos: .utility).async` blocks it replaces; the stderr reader runs only
    /// when `separateStderr` is true.
    private static func spawnDrainers(_ drainers: Drainers) {
        DispatchQueue.global(qos: .utility).async {
            drainers.outData.set(drainers.outPipe.fileHandleForReading.readDataToEndOfFile())
            drainers.outDone.signal()
        }
        if drainers.separateStderr {
            DispatchQueue.global(qos: .utility).async {
                drainers.errData.set(drainers.errPipe.fileHandleForReading.readDataToEndOfFile())
                drainers.errDone?.signal()
            }
        }
    }

    /// Timeout teardown: terminate, briefly await the termination handler, close the read handle(s)
    /// to unblock the drainers, then bounded-wait on them before throwing. Always throws — extracted
    /// verbatim from the former inline `guard … else` block so ordering is preserved.
    private static func failTimedOut(
        process: Process,
        finished: DispatchSemaphore,
        drainers: Drainers,
        pid: Int32
    ) throws -> Never {
        process.terminate()
        _ = finished.wait(timeout: .now() + .seconds(1))
        drainers.outPipe.fileHandleForReading.closeFile()
        if drainers.separateStderr { drainers.errPipe.fileHandleForReading.closeFile() }
        _ = drainers.outDone.wait(timeout: .now() + .seconds(1))
        _ = drainers.errDone?.wait(timeout: .now() + .seconds(1))
        throw ProcessRunError.timedOut(processID: pid)
    }
}
