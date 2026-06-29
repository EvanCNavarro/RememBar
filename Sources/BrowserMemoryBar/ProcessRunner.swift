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
}

/// The single CLI-process primitive. Spawns a process, drains its output, enforces a timeout, and
/// honors cooperative cancellation via `RunningProcessState` — the error-prone orchestration
/// (semaphore / timeout / terminate ordering, 1-or-2-pipe draining) shared by every CLI search
/// provider. Telemetry and error mapping are the caller's job and are injected via the callbacks /
/// typed throws; this type owns only the mechanics so there is exactly one place to get them right.
enum ProcessRunner {
    static func run(
        executableURL: URL,
        arguments: [String],
        timeout: DispatchTimeInterval,
        state: RunningProcessState,
        separateStderr: Bool,
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
        let outDone = DispatchSemaphore(value: 0)
        let errDone = separateStderr ? DispatchSemaphore(value: 0) : nil
        let outData = LockedData()
        let errData = LockedData()
        process.terminationHandler = { _ in finished.signal() }

        if state.isCancelled { throw ProcessRunError.cancelledBeforeLaunch }
        do {
            try process.run()
        } catch {
            throw ProcessRunError.launchFailed(error)
        }
        state.attachLaunched(process)
        let pid = process.processIdentifier
        onLaunched(pid)

        DispatchQueue.global(qos: .utility).async {
            outData.set(outPipe.fileHandleForReading.readDataToEndOfFile())
            outDone.signal()
        }
        if separateStderr {
            DispatchQueue.global(qos: .utility).async {
                errData.set(errPipe.fileHandleForReading.readDataToEndOfFile())
                errDone?.signal()
            }
        }

        if state.isCancelled, process.isRunning {
            onCancelRequestedAfterLaunch(pid)
            process.terminate()
        }

        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            _ = finished.wait(timeout: .now() + .seconds(1))
            outPipe.fileHandleForReading.closeFile()
            if separateStderr { errPipe.fileHandleForReading.closeFile() }
            _ = outDone.wait(timeout: .now() + .seconds(1))
            _ = errDone?.wait(timeout: .now() + .seconds(1))
            throw ProcessRunError.timedOut(processID: pid)
        }

        _ = outDone.wait(timeout: .now() + .seconds(1))
        _ = errDone?.wait(timeout: .now() + .seconds(1))

        if state.isCancelled { throw ProcessRunError.cancelledAfterLaunch(processID: pid) }

        return ProcessRunResult(
            processID: pid,
            terminationStatus: process.terminationStatus,
            stdout: outData.get(),
            stderr: separateStderr ? errData.get() : Data()
        )
    }
}
