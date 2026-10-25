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
/// Reads stdout before `waitUntilExit()` to avoid pipe-full deadlocks, supports a
/// timeout via `task.terminate()`, and cooperates with cancellation by terminating
/// the child when the calling `Task` is cancelled.
///
/// Note on `terminate()` race-safety: a `Process` must not be terminated before it has
/// launched. This runner uses an internal `LaunchState` lock to track whether the task
/// has actually started. The cancellation handler only terminates the process once it
/// has been marked started; if cancellation arrives before launch, the run path sees the
/// cancellation and aborts without ever calling `terminate()`. The timeout path relies
/// on `Process.terminationHandler` (set before `run()`) to deliver the result, avoiding
/// polling `isRunning`.
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

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global().async {
                    let resultBox = ResultBox()

                    task.terminationHandler = { process in
                        guard let output = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8),
                              let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else {
                            resultBox.set(.failure(ProcessRunnerError.outputDecodingFailed))
                            return
                        }
                        resultBox.set(.success(ProcessRunResult(
                            status: process.terminationStatus,
                            output: output,
                            timedOut: false,
                            stderr: stderr
                        )))
                    }

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
                            // Already cancelled before launch; don't run.
                            timeoutWorkItem.cancel()
                            continuation.resume(throwing: CancellationError())
                            return
                        }
                    } catch {
                        timeoutWorkItem.cancel()
                        continuation.resume(throwing: error)
                        return
                    }

                    // Wait for terminationHandler to deliver the result.
                    task.waitUntilExit()
                    timeoutWorkItem.cancel()

                    switch resultBox.result {
                    case .success(let result):
                        let final = ProcessRunResult(
                            status: result.status,
                            output: result.output,
                            timedOut: state.isTimedOut,
                            stderr: result.stderr
                        )
                        continuation.resume(returning: final)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    case .none:
                        continuation.resume(throwing: ProcessRunnerError.outputDecodingFailed)
                    }
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

    /// Returns `true` if the timeout fired before another outcome.
    func markTimedOut() -> Bool {
        lock.withLock {
            guard !started || !timedOut else { return false }
            timedOut = true
            return true
        }
    }

    var isTimedOut: Bool {
        lock.withLock { timedOut }
    }
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _result: Result<ProcessRunResult, Error>?

    var result: Result<ProcessRunResult, Error>? {
        lock.withLock { _result }
    }

    func set(_ result: Result<ProcessRunResult, Error>) {
        lock.withLock {
            guard _result == nil else { return }
            _result = result
        }
    }
}

private enum ProcessRunnerError: Error {
    case outputDecodingFailed
}
