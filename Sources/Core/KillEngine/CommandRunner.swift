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

/// Spawns an executable using an absolute path and an argv array.
/// Never invokes a shell and never performs PATH lookup.
public protocol CommandRunner: Sendable {
    func run(executable: String, arguments: [String]) throws -> CommandResult
}

public struct RealCommandRunner: CommandRunner {
    public let timeout: TimeInterval

    public init(timeout: TimeInterval = 10) {
        self.timeout = timeout
    }

    public func run(executable: String, arguments: [String]) throws -> CommandResult {
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
        process.terminationHandler = { _ in
            semaphore.signal()
        }

        try process.run()
        let waitResult = semaphore.wait(timeout: .now() + timeout)

        // Stop handlers before final drain to avoid racing the callbacks.
        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil

        if waitResult == .timedOut {
            process.terminate()
            process.waitUntilExit()
            throw CommandRunnerError.timeout
        }

        process.waitUntilExit()

        // Final drain in case any data arrived after handlers were removed.
        stdout.append(outputPipe.fileHandleForReading.readDataToEndOfFile())
        stderr.append(errorPipe.fileHandleForReading.readDataToEndOfFile())

        return CommandResult(
            exitCode: process.terminationStatus,
            stdout: String(data: stdout.data, encoding: .utf8) ?? "",
            stderr: String(data: stderr.data, encoding: .utf8) ?? ""
        )
    }
}

private final class PipeAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }
}

/// Records every invocation and returns canned output or errors.
public final class MockCommandRunner: CommandRunner, @unchecked Sendable {
    public private(set) var invocations: [(executable: String, arguments: [String])] = []
    public var results: [CommandResult] = []
    public var nextError: Error?

    public init() {}

    public func run(executable: String, arguments: [String]) throws -> CommandResult {
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
