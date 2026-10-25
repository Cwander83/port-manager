import Foundation

/// A concrete kill action produced by a rule.
///
/// Each case carries the exact command description shown in the confirmation
/// dialog plus the execution payload needed to carry it out.
public enum KillAction: Sendable, Equatable {
    /// Send SIGTERM directly to a PID via the `kill(2)` syscall.
    /// `processStartTime` is the snapshot of the process start time that the
    /// scanner captured. It must be re-verified before signaling.
    case killPid(
        pid: pid_t,
        processStartTime: Date?,
        commandDescription: String
    )

    /// Run `docker stop <containerID>`.
    case dockerStop(
        containerID: String,
        commandDescription: String,
        executable: String
    )

    /// Run `brew services stop <serviceName>`.
    case brewStop(
        serviceName: String,
        commandDescription: String,
        executable: String
    )

    /// POST /api/generate with `{"model": <model>, "keep_alive": 0}`
    /// to unload the model from the local Ollama server.
    case ollamaUnload(
        model: String,
        commandDescription: String,
        url: URL,
        method: String
    )
}

public enum KillEngineError: Error, Equatable {
    case validationFailure(reason: ValidationFailureReason)
    case dockerBinaryMissing
    case dockerDaemonUnavailable(message: String)
    case brewBinaryMissing
    case ollamaUnreachable
    case commandListUnavailable
}

public enum ValidationFailureReason: Equatable, Sendable {
    case invalidPID(pid: pid_t)
    case cannotSignalSelf(pid: pid_t)
    case unknownOwner(pid: pid_t)
    case foreignProcess(pid: pid_t, ownerUID: uid_t)
    case processIdentityChanged(pid: pid_t)
    case invalidContainerID(String)
    case containerLookupFailed(port: Int)
    case ambiguousContainerMatch(port: Int)
    case dockerProcessMismatch(pid: pid_t)
    case unmappedBrewProcess(processName: String)
    case ambiguousBrewService
    case invalidOllamaURL
    case ollamaModelNotLoaded(port: Int)
    case ambiguousModel
    case modelNotResolvable
    case invalidServiceName(String)
}

/// Determines whether it can stop a listener (sync) and, if so, resolves the
/// concrete action. The resolution may involve subprocesses or HTTP calls and
/// must therefore be `async throws`.
public protocol KillRule: Sendable {
    func canHandle(_ item: PortItem) -> Bool
    func makeAction(_ item: PortItem) async throws -> KillAction
}
