import Foundation

/// Result of running an external process.
public struct ProcessRunResult: Sendable, Equatable {
    public let status: Int32
    public let output: String
    public let timedOut: Bool
    public let stderr: String?

    public init(status: Int32, output: String, timedOut: Bool = false, stderr: String? = nil) {
        self.status = status
        self.output = output
        self.timedOut = timedOut
        self.stderr = stderr
    }
}

/// Abstracts process execution so scanners stay testable and cancellation-aware.
public protocol ProcessRunner: Sendable {
    func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> ProcessRunResult
}

/// Default runner that uses `Process` directly.
///
/// Drains stdout/stderr concurrently with the child to avoid pipe-full deadlocks,
/// supports a timeout via `task.terminate()`, and cooperates with cancellation by
/// terminating the child when the calling `Task` is cancelled.
///
/// Note on `terminate()` race-safety: a `Process` must not be terminated before it has
/// launched. This runner uses an internal `LaunchState` lock to track whether the task
/// has actually started. The cancellation and timeout handlers only terminate the
/// process once it has been marked started; if cancellation arrives before launch, the
/// run path sees the cancellation and aborts without ever calling `terminate()`.
public final class RealProcessRunner: ProcessRunner, @unchecked Sendable {
    public init() {}

    public func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> ProcessRunResult {
        let task = Process()
        task.executableURL = executableURL
        task.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe

        let state = LaunchState()
        let outBox = DataBox()
        let errBox = DataBox()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global().async {
                    let timeoutWorkItem = DispatchWorkItem {
                        if state.markTimedOut() {
                            task.terminate()
                        }
                    }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)

                    do {
                        if state.markStarted() {
                            try task.run()
                        } else {
                            timeoutWorkItem.cancel()
                            continuation.resume(throwing: CancellationError())
                            return
                        }
                    } catch {
                        timeoutWorkItem.cancel()
                        continuation.resume(throwing: error)
                        return
                    }

                    // Drain pipes concurrently while the child is running so the child
                    // never blocks on a full pipe buffer.
                    let drainGroup = DispatchGroup()
                    drainGroup.enter()
                    DispatchQueue.global().async {
                        outBox.set(outPipe.fileHandleForReading.readDataToEndOfFile())
                        drainGroup.leave()
                    }
                    drainGroup.enter()
                    DispatchQueue.global().async {
                        errBox.set(errPipe.fileHandleForReading.readDataToEndOfFile())
                        drainGroup.leave()
                    }

                    task.waitUntilExit()
                    drainGroup.wait()
                    timeoutWorkItem.cancel()

                    guard let output = String(data: outBox.data, encoding: .utf8),
                          let stderr = String(data: errBox.data, encoding: .utf8) else {
                        continuation.resume(throwing: ProcessRunnerError.outputDecodingFailed)
                        return
                    }

                    continuation.resume(returning: ProcessRunResult(
                        status: task.terminationStatus,
                        output: output,
                        timedOut: state.isTimedOut,
                        stderr: stderr
                    ))
                }
            }
        } onCancel: {
            if state.markCancelled() {
                task.terminate()
            }
        }
    }
}

private final class LaunchState: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var cancelled = false
    private var timedOut = false

    /// Returns `true` if the caller should proceed with `task.run()`.
    func markStarted() -> Bool {
        lock.withLock {
            guard !cancelled else { return false }
            started = true
            return true
        }
    }

    /// Returns `true` if the process has started and should be terminated now.
    func markCancelled() -> Bool {
        lock.withLock {
            cancelled = true
            return started
        }
    }

    /// Returns `true` if the timeout fired before another outcome and the process had
    /// already started, allowing a safe `terminate()` call.
    func markTimedOut() -> Bool {
        lock.withLock {
            guard started, !timedOut else { return false }
            timedOut = true
            return true
        }
    }

    var isTimedOut: Bool {
        lock.withLock { timedOut }
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _data: Data?

    var data: Data {
        lock.withLock { _data ?? Data() }
    }

    func set(_ data: Data) {
        lock.withLock {
            guard _data == nil else { return }
            _data = data
        }
    }
}

private enum ProcessRunnerError: Error {
    case outputDecodingFailed
}
