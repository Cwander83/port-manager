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
}

/// Spawns an executable using an absolute path and an argv array.
/// Never invokes a shell and never performs PATH lookup.
public protocol CommandRunner {
    func run(executable: String, arguments: [String]) throws -> CommandResult
}

public struct RealCommandRunner: CommandRunner {
    public init() {}

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

        try process.run()
        process.waitUntilExit()

        let stdout = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        return CommandResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}

/// Records every invocation and returns canned output or errors.
public final class MockCommandRunner: CommandRunner {
    public private(set) var invocations: [(executable: String, arguments: [String])] = []
    public var results: [CommandResult] = []
    public var nextError: Error?

    public init() {}

    public func run(executable: String, arguments: [String]) throws -> CommandResult {
        invocations.append((executable, arguments))
        if let error = nextError {
            throw error
        }
        guard !results.isEmpty else {
            return CommandResult(exitCode: 0, stdout: "", stderr: "")
        }
        return results.removeFirst()
    }
}
