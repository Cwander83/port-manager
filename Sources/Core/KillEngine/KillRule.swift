import Foundation

/// A concrete kill action produced by a rule.
///
/// Each case carries the exact command description shown in the confirmation
/// dialog plus the execution payload needed to carry it out.
public enum KillAction: Sendable, Equatable {
    /// Send SIGTERM directly to a PID via the `kill(2)` syscall.
    case killPid(pid: pid_t, commandDescription: String)

    /// Run `docker stop <containerID>`.
    case dockerStop(
        containerID: String,
        commandDescription: String,
        executable: String,
        arguments: [String]
    )

    /// Run `brew services stop <serviceName>`.
    case brewStop(
        serviceName: String,
        commandDescription: String,
        executable: String,
        arguments: [String]
    )

    /// DELETE /api/unload against the local Ollama server.
    case ollamaUnload(
        model: String,
        commandDescription: String,
        url: URL,
        method: String,
        body: Data
    )
}

public enum KillEngineError: Error, Equatable {
    case validationFailure(reason: ValidationFailureReason)
    case dockerBinaryMissing
    case brewBinaryMissing
}

public enum ValidationFailureReason: Equatable, Sendable {
    case invalidPID(pid: pid_t)
    case foreignProcess(pid: pid_t, ownerUID: uid_t)
    case invalidContainerID(String)
    case containerLookupFailed(port: Int, output: String)
    case unmappedBrewProcess(processName: String)
    case ollamaModelNotLoaded(port: Int)
}

/// Determines how to stop a listener and returns a `KillAction`.
public protocol KillRule {
    func canHandle(_ item: PortItem) -> Bool
    func makeAction(_ item: PortItem) throws -> KillAction
}
