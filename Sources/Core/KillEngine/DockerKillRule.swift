import Foundation

struct DockerKillRule: KillRule {
    private let runner: CommandRunner
    private let nameProvider: ProcessNameProvider
    private let primaryPath: String
    private let fallbackPath: String

    init(
        runner: CommandRunner,
        nameProvider: ProcessNameProvider = ProcessOwnerValidator(),
        primaryPath: String = "/opt/homebrew/bin/docker",
        fallbackPath: String = "/usr/local/bin/docker"
    ) {
        self.runner = runner
        self.nameProvider = nameProvider
        self.primaryPath = primaryPath
        self.fallbackPath = fallbackPath
    }

    func canHandle(_ item: PortItem) -> Bool {
        item.kind == .docker || item.processName.hasPrefix("com.docker")
    }

    func makeAction(_ item: PortItem) throws -> KillAction {
        let dockerPath = resolveDockerPath()
        guard FileManager.default.fileExists(atPath: dockerPath) else {
            throw KillEngineError.dockerBinaryMissing
        }

        guard let currentName = nameProvider.processName(of: item.pid),
              currentName.hasPrefix("com.docker") else {
            throw KillEngineError.validationFailure(reason: .dockerProcessMismatch(pid: item.pid))
        }

        let result = try runner.run(
            executable: dockerPath,
            arguments: ["ps", "--format", "{{.ID}}\t{{.Ports}}"]
        )
        guard result.exitCode == 0 else {
            let trimmed = result.stderr.split(separator: "\n").first.map(String.init) ?? ""
            throw KillEngineError.dockerDaemonUnavailable(message: trimmed)
        }

        let matches = try matchingContainers(for: item, in: result.stdout)
        guard matches.count == 1 else {
            if matches.isEmpty {
                throw KillEngineError.validationFailure(reason: .containerLookupFailed(port: item.port))
            }
            throw KillEngineError.validationFailure(reason: .ambiguousContainerMatch(port: item.port))
        }
        let containerID = matches[0]

        guard validateContainerID(containerID) else {
            throw KillEngineError.validationFailure(reason: .invalidContainerID(containerID))
        }

        return .dockerStop(
            containerID: containerID,
            commandDescription: "docker stop \(containerID)",
            executable: dockerPath
        )
    }

    private func resolveDockerPath() -> String {
        if FileManager.default.fileExists(atPath: primaryPath) {
            return primaryPath
        }
        return fallbackPath
    }

    private func matchingContainers(for item: PortItem, in output: String) throws -> [String] {
        var ids: [String] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 2 else { continue }
            let id = String(parts[0])
            let ports = String(parts[1])
            if ports.contains(item.port, localAddress: item.localAddress) {
                ids.append(id)
            }
        }
        return ids
    }

    private func validateContainerID(_ id: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: "^[0-9a-f]{12,64}$") else {
            return false
        }
        let range = NSRange(id.startIndex..., in: id)
        return regex.firstMatch(in: id, options: [], range: range) != nil
    }
}

private extension String {
    /// Returns true if any Docker port mapping in this string exposes `port`
    /// on a host address matching `localAddress` (nil matches any host).
    /// Supports ranges (`0.0.0.0:8000-8010->...`) and IPv6 (`[::]:8080`).
    func contains(_ port: Int, localAddress: String?) -> Bool {
        let tokens = self.split(separator: ",")
        for token in tokens {
            let trimmed = token.trimmingCharacters(in: .whitespaces)
            if trimmed.matchesDockerPort(port: port, localAddress: localAddress) {
                return true
            }
        }
        return false
    }

    private func matchesDockerPort(port: Int, localAddress: String?) -> Bool {
        // Token like "[::]:8080->8080/tcp" or "0.0.0.0:8000-8010->8000-8010/tcp".
        let parts = self.split(separator: "->", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let localPart = String(parts[0])

        guard let lastColonIndex = localPart.lastIndex(of: ":") else { return false }
        let host = String(localPart[..<lastColonIndex])
        let portRange = String(localPart[localPart.index(after: lastColonIndex)...])

        if let localAddress = localAddress {
            let normalizedHost = host.isEmpty ? "::" : host
            guard normalizedHost == localAddress else { return false }
        }

        return portRange.matchesPortRange(port: port)
    }
}

private extension String {
    func matchesPortRange(port: Int) -> Bool {
        let trimmed = self.trimmingCharacters(in: .whitespaces)
        if let single = Int(trimmed) {
            return single == port
        }
        let bounds = trimmed.split(separator: "-")
        guard bounds.count == 2,
              let lower = Int(bounds[0]),
              let upper = Int(bounds[1]) else {
            return false
        }
        return port >= lower && port <= upper
    }
}
