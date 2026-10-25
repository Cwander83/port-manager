import Foundation

/// Errors that occur while carrying out an already-validated `KillAction`.
public enum KillExecutionError: Error {
    case commandFailed(CommandResult)
    case httpFailure
    case signalDeliveryFailed(pid: pid_t, errno: Int32)
}
