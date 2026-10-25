import Foundation

/// Result of running an external executable.
public struct CommandResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum CommandRunnerError: Error, Equatable {
    case relativePath(String)
    case timeout
}

extension CommandRunnerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .relativePath(let path):
            return "Executable path must be absolute: \(path)."
        case .timeout:
            return "Command timed out."
        }
    }
}

/// Spawns an executable using an absolute path and an argv array.
/// Never invokes a shell and never performs PATH lookup.
///
/// Callers can supply a per-call `timeout`. The default is 10 seconds.
public protocol CommandRunner: Sendable {
    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> CommandResult
}

extension CommandRunner {
    public func run(executable: String, arguments: [String]) async throws -> CommandResult {
        try await run(executable: executable, arguments: arguments, timeout: 10)
    }
}

public struct RealCommandRunner: CommandRunner {
    public init() {}

    public func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try self.runSync(executable: executable, arguments: arguments, timeout: timeout)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func runSync(executable: String, arguments: [String], timeout: TimeInterval) throws -> CommandResult {
        guard executable.hasPrefix("/") else {
            throw CommandRunnerError.relativePath(executable)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let stdout = PipeAccumulator()
        let stderr = PipeAccumulator()

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                stdout.append(data)
            }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                stderr.append(data)
            }
        }

        let semaphore = DispatchSemaphore(value: 0)
        let statusBox = TerminationStatusBox()
        process.terminationHandler = { proc in
            statusBox.set(proc.terminationStatus)
            semaphore.signal()
        }

        try process.run()
        let waitResult = semaphore.wait(timeout: .now() + timeout)

        // Stop handlers before final drain to avoid racing the callbacks.
        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil

        if waitResult == .timedOut {
            // First polite SIGTERM.
            process.terminate()
            let killWait = semaphore.wait(timeout: .now() + 3)
            if killWait == .timedOut || !statusBox.didTerminate {
                // Escalate to SIGKILL if the process ignored SIGTERM.
                kill(process.processIdentifier, SIGKILL)
                _ = semaphore.wait(timeout: .now() + 1)
            }
            // Ensure the child is reaped before we throw; a zombie is impossible
            // to kill again and leaks resources.
            process.waitUntilExit()
            throw CommandRunnerError.timeout
        }

        process.waitUntilExit()

        // Final drain in case any data arrived after handlers were removed.
        stdout.append(outputPipe.fileHandleForReading.readDataToEndOfFile())
        stderr.append(errorPipe.fileHandleForReading.readDataToEndOfFile())

        return CommandResult(
            exitCode: statusBox.exitCode,
            stdout: String(data: stdout.data, encoding: .utf8) ?? "",
            stderr: String(data: stderr.data, encoding: .utf8) ?? ""
        )
    }
}

/// Thread-safe accumulator for pipe output. The callbacks are the only
/// writers; `run()` reads after the process terminates.
private final class PipeAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }
}

/// Thread-safe box for the process termination status written from the
/// termination handler and read after the process exits.
private final class TerminationStatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _exitCode: Int32 = 0
    private var _didTerminate: Bool = false

    var exitCode: Int32 {
        lock.lock(); defer { lock.unlock() }
        return _exitCode
    }

    var didTerminate: Bool {
        lock.lock(); defer { lock.unlock() }
        return _didTerminate
    }

    func set(_ code: Int32) {
        lock.lock()
        _exitCode = code
        _didTerminate = true
        lock.unlock()
    }
}

/// Records every invocation and returns canned output or errors.
public final class MockCommandRunner: CommandRunner, @unchecked Sendable {
    public private(set) var invocations: [(executable: String, arguments: [String])] = []
    public var results: [CommandResult] = []
    public var nextError: Error?

    public init() {}

    public func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> CommandResult {
        invocations.append((executable, arguments))
        if let error = nextError {
            nextError = nil
            throw error
        }
        guard !results.isEmpty else {
            return CommandResult(exitCode: 1, stdout: "", stderr: "unstubbed mock invocation")
        }
        return results.removeFirst()
    }
}
