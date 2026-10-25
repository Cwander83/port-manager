import Foundation
import Darwin

/// Rule-based dispatcher that chooses the right way to stop a listener.
public struct KillEngine {
    public let rules: [KillRule]
    private let runner: CommandRunner
    private let httpTransport: HTTPTransport
    private let identityProvider: ProcessIdentityProvider
    private let nameProvider: ProcessNameProvider

    public init(
        runner: CommandRunner = RealCommandRunner(),
        httpTransport: HTTPTransport = RealHTTPTransport(),
        identityProvider: ProcessIdentityProvider = ProcessOwnerValidator(),
        nameProvider: ProcessNameProvider = ProcessOwnerValidator(),
        rules: [KillRule]? = nil
    ) {
        self.runner = runner
        self.httpTransport = httpTransport
        self.identityProvider = identityProvider
        self.nameProvider = nameProvider
        self.rules = rules ?? [
            DockerKillRule(runner: runner, nameProvider: nameProvider),
            OllamaUnloadRule(transport: httpTransport),
            BrewServiceRule(runner: runner),
            DefaultKillRule(
                validator: identityProvider as? ProcessOwnershipValidator ?? ProcessOwnerValidator(),
                identityProvider: identityProvider
            )
        ]
    }

    /// Returns the first matching rule's action.
    public func action(for item: PortItem) throws -> KillAction {
        for rule in rules {
            guard rule.canHandle(item) else { continue }
            return try rule.makeAction(item)
        }
        return try DefaultKillRule(identityProvider: identityProvider).makeAction(item)
    }

    /// Executes a validated action.
    ///
    /// Must not be called from the main thread; the method is `async` so callers
    /// can await it off the main actor. `escalate` opts in to SIGKILL after a
    /// short SIGTERM grace period.
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

        case .ollamaUnload(let model, _, let url, let method, let body):
            try await executeOllamaUnload(model: model, url: url, method: method, body: body)
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
        let result = try commandRunner.run(executable: executable, arguments: ["stop", containerID])
        guard result.exitCode == 0 else {
            throw KillExecutionError.commandFailed(result)
        }
    }

    private func executeBrewStop(
        serviceName: String,
        executable: String,
        using commandRunner: CommandRunner
    ) async throws {
        let result = try commandRunner.run(executable: executable, arguments: ["services", "stop", serviceName])
        guard result.exitCode == 0 else {
            throw KillExecutionError.commandFailed(result)
        }
    }

    private func executeOllamaUnload(
        model: String,
        url: URL,
        method: String,
        body: Data
    ) async throws {
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
    /// Pid-reuse mitigation: the process start time captured at scan time is
    /// re-read immediately before signaling. A mismatch aborts with a typed
    /// error. A residual race remains between the re-read and the signal, but
    /// this reduces the window from scan-to-kill to microseconds.
    private func killProcess(pid: pid_t, capturedStartTime: Date?, escalate: Bool) async throws {
        guard pid > 0 else {
            throw KillEngineError.validationFailure(reason: .invalidPID(pid: pid))
        }
        guard pid != getpid() else {
            throw KillEngineError.validationFailure(reason: .invalidPID(pid: pid))
        }

        guard let identity = identityProvider.identity(of: pid) else {
            throw KillEngineError.validationFailure(reason: .unknownOwner(pid: pid))
        }
        guard identity.uid == getuid() else {
            throw KillEngineError.validationFailure(reason: .foreignProcess(pid: pid, ownerUID: identity.uid))
        }

        if let capturedStartTime = capturedStartTime {
            guard identity.startTime == capturedStartTime else {
                throw KillEngineError.validationFailure(reason: .processIdentityChanged(pid: pid))
            }
        }

        try deliverSignal(pid: pid, signal: SIGTERM)

        if escalate {
            try await Task.sleep(nanoseconds: 250_000_000) // 0.25s grace
            if isProcessAlive(pid: pid) {
                try deliverSignal(pid: pid, signal: SIGKILL)
            }
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
}
