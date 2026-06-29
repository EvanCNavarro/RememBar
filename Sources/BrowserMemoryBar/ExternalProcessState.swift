import Foundation

final class RunningProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private var launchedProcess: Process?
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func attachLaunched(_ process: Process) {
        let shouldTerminate: Bool = lock.withLock {
            launchedProcess = process
            return cancelled
        }
        if shouldTerminate, process.isRunning {
            process.terminate()
        }
    }

    func cancel() {
        let process = lock.withLock {
            cancelled = true
            return launchedProcess
        }
        if process?.isRunning == true {
            process?.terminate()
        }
    }
}

final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func set(_ data: Data) {
        lock.withLock {
            self.data = data
        }
    }

    func get() -> Data {
        lock.withLock { data }
    }
}
