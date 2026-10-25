import Foundation

/// Result of running an external process.
public struct ProcessRunResult: Sendable, Equatable {
    public let status: Int32
    public let output: String

    public init(status: Int32, output: String) {
        self.status = status
        self.output = output
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
public struct RealProcessRunner: ProcessRunner {
    public init() {}

    public func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> ProcessRunResult {
        let task = Process()
        task.executableURL = executableURL
        task.arguments = arguments

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global().async {
                    do {
                        try task.run()
                    } catch {
                        continuation.resume(throwing: error)
                        return
                    }

                    let timeoutWorkItem = DispatchWorkItem {
                        if task.isRunning {
                            task.terminate()
                        }
                    }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)

                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    task.waitUntilExit()
                    timeoutWorkItem.cancel()

                    guard let output = String(data: data, encoding: .utf8) else {
                        continuation.resume(throwing: ProcessRunnerError.outputDecodingFailed)
                        return
                    }

                    continuation.resume(returning: ProcessRunResult(
                        status: task.terminationStatus,
                        output: output
                    ))
                }
            }
        } onCancel: {
            task.terminate()
        }
    }
}

private enum ProcessRunnerError: Error {
    case outputDecodingFailed
}
