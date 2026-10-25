import Foundation

/// Errors that occur while carrying out an already-validated `KillAction`.
public enum KillExecutionError: Error {
    case commandFailed(CommandResult)
    case httpFailure
    case signalDeliveryFailed(pid: pid_t, errno: Int32)
    case processStillAliveAfterSIGTERM(pid: pid_t)
    case timeout
}

extension KillEngineError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .validationFailure(let reason):
            return reason.localizedDescription
        case .dockerBinaryMissing:
            return "Docker CLI not found at /opt/homebrew/bin/docker or /usr/local/bin/docker."
        case .dockerDaemonUnavailable(let message):
            return "Docker daemon is unavailable — stop the container via Docker Desktop. \(message)"
        case .brewBinaryMissing:
            return "Homebrew not found at /opt/homebrew/bin/brew or /usr/local/bin/brew."
        case .ollamaUnreachable:
            return "Ollama API did not respond. Make sure Ollama is running on port 11434."
        }
    }
}

extension ValidationFailureReason: LocalizedError {
    public var errorDescription: String? { localizedDescription }

    public var localizedDescription: String {
        switch self {
        case .invalidPID(let pid):
            return "Invalid PID \(pid)."
        case .unknownOwner(let pid):
            return "Cannot verify ownership of process \(pid)."
        case .foreignProcess(let pid, let ownerUID):
            return "Process \(pid) is owned by user \(ownerUID), not you."
        case .processIdentityChanged(let pid):
            return "Process \(pid) was replaced before the kill could complete (pid reuse)."
        case .invalidContainerID(let id):
            return "Refusing unsafe Docker container ID \"\(id)\"."
        case .containerLookupFailed(let port):
            return "Could not find a Docker container listening on port \(port)."
        case .ambiguousContainerMatch(let port):
            return "Multiple Docker containers match port \(port); stop the right one manually."
        case .dockerProcessMismatch(let pid):
            return "Process \(pid) no longer belongs to Docker; rule aborted."
        case .unmappedBrewProcess(let processName):
            return "Unknown Homebrew service for process \"\(processName)\"."
        case .ollamaModelNotLoaded(let port):
            return "No Ollama model appears loaded on port \(port)."
        case .ambiguousModel:
            return "Multiple loaded models could match this listener; unload the model manually."
        }
    }
}

extension KillExecutionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .commandFailed(let result):
            let trimmed = result.stderr.split(separator: "\n").first.map(String.init) ?? result.stderr
            return "Command failed (exit \(result.exitCode)): \(trimmed)"
        case .httpFailure:
            return "Ollama API request failed."
        case .signalDeliveryFailed(let pid, let errno):
            return "Failed to send signal to PID \(pid): error \(errno)."
        case .processStillAliveAfterSIGTERM(let pid):
            return "Process \(pid) ignored SIGTERM; enable escalation to send SIGKILL."
        case .timeout:
            return "Command timed out."
        }
    }
}
