import Foundation
import Darwin

/// Rule-based dispatcher that chooses the right way to stop a listener.
public struct KillEngine {
    public let rules: [KillRule]
    private let runner: CommandRunner
    private let httpTransport: HTTPTransport

    public init(
        runner: CommandRunner = RealCommandRunner(),
        httpTransport: HTTPTransport = RealHTTPTransport(),
        rules: [KillRule]? = nil
    ) {
        self.runner = runner
        self.httpTransport = httpTransport
        self.rules = rules ?? [
            DockerKillRule(runner: runner),
            OllamaUnloadRule(transport: httpTransport),
            BrewServiceRule(runner: runner),
            DefaultKillRule()
        ]
    }

    /// Returns the first matching rule's action.
    ///
    /// If the Docker or Homebrew binary is missing, this falls back to killing
    /// the proxy PID with an explanatory note in `commandDescription`.
    /// That fallback is intentionally blunt: without the CLI we cannot reach
    /// the real daemon-managed process, but it still terminates the local
    /// listener. See ADR-001 §7 and the Docker/Brew rule comments.
    public func action(for item: PortItem) throws -> KillAction {
        for rule in rules {
            guard rule.canHandle(item) else { continue }
            do {
                return try rule.makeAction(item)
            } catch KillEngineError.dockerBinaryMissing {
                return fallbackKillAction(
                    for: item,
                    note: "Docker CLI unavailable; stopping proxy process as fallback"
                )
            } catch KillEngineError.brewBinaryMissing {
                return fallbackKillAction(
                    for: item,
                    note: "Homebrew unavailable; stopping proxy process as fallback"
                )
            }
        }
        return try DefaultKillRule().makeAction(item)
    }

    /// Executes a validated action.
    ///
    /// - `killPid`: direct `kill(2)` syscall.
    /// - `dockerStop` / `brewStop`: via the supplied `CommandRunner`.
    /// - `ollamaUnload`: via the injected `HTTPTransport`.
    public func execute(_ action: KillAction, runner: CommandRunner) throws {
        switch action {
        case .killPid(let pid, _):
            try killProcess(pid: pid)

        case .dockerStop(_, _, let executable, let arguments),
             .brewStop(_, _, let executable, let arguments):
            let result = try runner.run(executable: executable, arguments: arguments)
            guard result.exitCode == 0 else {
                throw KillExecutionError.commandFailed(result)
            }

        case .ollamaUnload(_, _, let url, let method, let body):
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.httpBody = body
            let (_, response) = try httpTransport.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw KillExecutionError.httpFailure
            }
        }
    }

    private func fallbackKillAction(for item: PortItem, note: String) -> KillAction {
        .killPid(pid: item.pid, commandDescription: "kill \(item.pid) (\(note))")
    }

    private func killProcess(pid: pid_t) throws {
        guard pid > 0 else {
            throw KillEngineError.validationFailure(reason: .invalidPID(pid: pid))
        }
        let validator = ProcessOwnerValidator()
        guard validator.isOwnedByCurrentUser(pid: pid) else {
            let owner = validator.ownerUID(of: pid) ?? 0
            throw KillEngineError.validationFailure(reason: .foreignProcess(pid: pid, ownerUID: owner))
        }
        let status = kill(pid, SIGTERM)
        guard status == 0 else {
            throw KillExecutionError.signalDeliveryFailed(pid: pid, errno: errno)
        }
    }
}
