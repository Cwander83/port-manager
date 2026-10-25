import Foundation

struct DockerKillRule: KillRule {
    private let runner: CommandRunner
    private let primaryPath: String
    private let fallbackPath: String

    init(
        runner: CommandRunner,
        primaryPath: String = "/opt/homebrew/bin/docker",
        fallbackPath: String = "/usr/local/bin/docker"
    ) {
        self.runner = runner
        self.primaryPath = primaryPath
        self.fallbackPath = fallbackPath
    }

    func canHandle(_ item: PortItem) -> Bool {
        item.kind == .docker || item.processName == "com.docker.backend"
    }

    func makeAction(_ item: PortItem) throws -> KillAction {
        let dockerPath = resolveDockerPath()
        guard FileManager.default.fileExists(atPath: dockerPath) else {
            throw KillEngineError.dockerBinaryMissing
        }

        let result = try runner.run(
            executable: dockerPath,
            arguments: ["ps", "--format", "{{.ID}}\t{{.Ports}}"]
        )
        let containerID = try resolveContainerID(for: item.port, from: result.stdout)

        guard validateContainerID(containerID) else {
            throw KillEngineError.validationFailure(reason: .invalidContainerID(containerID))
        }

        return .dockerStop(
            containerID: containerID,
            commandDescription: "docker stop \(containerID)",
            executable: dockerPath,
            arguments: ["stop", containerID]
        )
    }

    private func resolveDockerPath() -> String {
        if FileManager.default.fileExists(atPath: primaryPath) {
            return primaryPath
        }
        return fallbackPath
    }

    private func resolveContainerID(for port: Int, from output: String) throws -> String {
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 2 else { continue }
            let id = String(parts[0])
            let ports = String(parts[1])
            if ports.contains(":\(port)->") {
                return id
            }
        }
        throw KillEngineError.validationFailure(reason: .containerLookupFailed(port: port, output: output))
    }

    private func validateContainerID(_ id: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: "^[0-9a-f]{12,64}$") else {
            return false
        }
        let range = NSRange(id.startIndex..., in: id)
        return regex.firstMatch(in: id, options: [], range: range) != nil
    }
}
