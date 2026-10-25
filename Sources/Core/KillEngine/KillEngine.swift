import Foundation
import Darwin

/// Rule-based dispatcher that chooses the right way to stop a listener.
public struct KillEngine: Sendable {
    public let rules: [KillRule]
    private let httpTransport: HTTPTransport
    private let identityProvider: ProcessIdentityProvider

    public init(
        runner: CommandRunner = RealCommandRunner(),
        httpTransport: HTTPTransport = RealHTTPTransport(),
        identityProvider: ProcessIdentityProvider = ProcessOwnerValidator(),
        rules: [KillRule]? = nil
    ) {
        self.httpTransport = httpTransport
        self.identityProvider = identityProvider
        self.rules = rules ?? [
            DockerKillRule(runner: runner, nameProvider: ProcessOwnerValidator(), identityProvider: identityProvider),
            OllamaUnloadRule(transport: httpTransport),
            BrewServiceRule(runner: runner),
            DefaultKillRule(identityProvider: identityProvider)
        ]
    }

    /// Returns the first matching rule's action.
    ///
    /// This method is `async throws` because resolving an action may require
    /// subprocesses (`docker ps`, `brew services list`) or HTTP calls
    /// (`/api/ps`). Do not call it from the main thread; await it from a
    /// background task.
    public func action(for item: PortItem) async throws -> KillAction {
        for rule in rules {
            guard rule.canHandle(item) else { continue }
            return try await rule.makeAction(item)
        }
        return try await DefaultKillRule(identityProvider: identityProvider).makeAction(item)
    }

    /// Executes a validated action.
    ///
    /// `commandRunner` must be the same `CommandRunner` instance that produced
    /// the action (e.g. the one passed to `KillEngine` init or used to resolve
    /// the rule). Passing a different runner is a programming error and may
    /// bypass stubbing/mocks.
    ///
    /// `escalate` opts in to SIGKILL after a short SIGTERM grace period.
    public func execute(
        _ action: KillAction,
        using commandRunner: CommandRunner,
        escalate: Bool = false
    ) async throws {
        switch action {
        case .killPid(let pid, let capturedStartTime, _):
            try await killProcess(pid: pid, capturedStartTime: capturedStartTime, escalate: escalate)

        case .dockerStop(let containerID, _, let executable):
            try await executeDockerStop(containerID: containerID, executable: executable, using: commandRunner)

        case .brewStop(let serviceName, _, let executable):
            try await executeBrewStop(serviceName: serviceName, executable: executable, using: commandRunner)

        case .ollamaUnload(let model, _, let url, let method):
            try await executeOllamaUnload(model: model, url: url, method: method)
        }
    }

    private func executeDockerStop(
        containerID: String,
        executable: String,
        using commandRunner: CommandRunner
    ) async throws {
        guard validateContainerID(containerID) else {
            throw KillEngineError.validationFailure(reason: .invalidContainerID(containerID))
        }
        let result = try await commandRunner.run(
            executable: executable,
            arguments: ["stop", containerID],
            timeout: 30
        )
        guard result.exitCode == 0 else {
            throw KillExecutionError.commandFailed(result)
        }
    }

    private func executeBrewStop(
        serviceName: String,
        executable: String,
        using commandRunner: CommandRunner
    ) async throws {
        guard validateServiceName(serviceName) else {
            throw KillEngineError.validationFailure(reason: .invalidServiceName(serviceName))
        }
        let result = try await commandRunner.run(
            executable: executable,
            arguments: ["services", "stop", serviceName],
            timeout: 15
        )
        guard result.exitCode == 0 else {
            throw KillExecutionError.commandFailed(result)
        }
    }

    private func executeOllamaUnload(
        model: String,
        url: URL,
        method: String
    ) async throws {
        guard url.scheme == "http",
              let host = url.host, host == "127.0.0.1",
              let port = url.port, port == 11434,
              url.path == "/api/generate" else {
            throw KillEngineError.validationFailure(reason: .invalidOllamaURL)
        }

        let body = try JSONSerialization.data(withJSONObject: ["model": model, "keep_alive": 0])
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try httpTransport.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw KillExecutionError.httpFailure
        }
    }

    /// Sends SIGTERM via `kill(2)`. If `escalate` is true and the process is
    /// still alive after a short grace period, sends SIGKILL.
    ///
    /// Pid-reuse mitigation: the process start time captured when the action
    /// was built is re-read immediately before signaling and compared at second
    /// granularity. A mismatch aborts with a typed error. A residual race
    /// remains between the re-read and the signal, and two distinct processes
    /// that start within the same second could be indistinguishable. macOS PID
    /// allocation makes same-second reuse effectively unreachable in practice.
    private func killProcess(pid: pid_t, capturedStartTime: Date?, escalate: Bool) async throws {
        guard pid > 0 else {
            throw KillEngineError.validationFailure(reason: .invalidPID(pid: pid))
        }
        guard pid != getpid() else {
            throw KillEngineError.validationFailure(reason: .cannotSignalSelf(pid: pid))
        }

        guard let identity = identityProvider.identity(of: pid) else {
            throw KillEngineError.validationFailure(reason: .unknownOwner(pid: pid))
        }
        guard identity.uid == getuid() else {
            throw KillEngineError.validationFailure(reason: .foreignProcess(pid: pid, ownerUID: identity.uid))
        }

        if let capturedStartTime = capturedStartTime {
            guard sameStart(identity.startTime, capturedStartTime) else {
                throw KillEngineError.validationFailure(reason: .processIdentityChanged(pid: pid))
            }
        }

        try deliverSignal(pid: pid, signal: SIGTERM)

        if escalate {
            try await Task.sleep(nanoseconds: 250_000_000) // 0.25s grace
            guard isProcessAlive(pid: pid) else { return }
            guard let refreshedIdentity = identityProvider.identity(of: pid),
                  sameStart(refreshedIdentity.startTime, capturedStartTime ?? identity.startTime),
                  refreshedIdentity.uid == identity.uid else {
                throw KillEngineError.validationFailure(reason: .processIdentityChanged(pid: pid))
            }
            try deliverSignal(pid: pid, signal: SIGKILL)
        }
    }

    private func deliverSignal(pid: pid_t, signal: Int32) throws {
        let status = kill(pid, signal)
        guard status == 0 else {
            throw KillExecutionError.signalDeliveryFailed(pid: pid, errno: errno)
        }
    }

    private func isProcessAlive(pid: pid_t) -> Bool {
        // Sending signal 0 performs error checking without delivering a signal.
        return kill(pid, 0) == 0
    }

    private func validateContainerID(_ id: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: "^[0-9a-f]{12,64}$") else {
            return false
        }
        let range = NSRange(id.startIndex..., in: id)
        return regex.firstMatch(in: id, options: [], range: range) != nil
    }

    private func validateServiceName(_ name: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: "^[A-Za-z0-9@._+-]+$") else {
            return false
        }
        let range = NSRange(name.startIndex..., in: name)
        return !name.isEmpty && !name.hasPrefix("-") && regex.firstMatch(in: name, options: [], range: range) != nil
    }
}
