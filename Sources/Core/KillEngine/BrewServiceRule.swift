import Foundation

struct BrewServiceRule: KillRule {
    private let runner: CommandRunner
    private let primaryPath: String
    private let fallbackPath: String

    init(
        runner: CommandRunner,
        primaryPath: String = "/opt/homebrew/bin/brew",
        fallbackPath: String = "/usr/local/bin/brew"
    ) {
        self.runner = runner
        self.primaryPath = primaryPath
        self.fallbackPath = fallbackPath
    }

    func canHandle(_ item: PortItem) -> Bool {
        item.kind == .brew
    }

    func makeAction(_ item: PortItem) throws -> KillAction {
        let brewPath = resolveBrewPath()
        guard FileManager.default.fileExists(atPath: brewPath) else {
            throw KillEngineError.brewBinaryMissing
        }

        let serviceName = try BrewServiceNameMapping.serviceName(for: item.processName)

        return .brewStop(
            serviceName: serviceName,
            commandDescription: "brew services stop \(serviceName)",
            executable: brewPath,
            arguments: ["services", "stop", serviceName]
        )
    }

    private func resolveBrewPath() -> String {
        if FileManager.default.fileExists(atPath: primaryPath) {
            return primaryPath
        }
        return fallbackPath
    }
}

/// Process name to `brew services stop <name>` mapping.
///
/// The executable name reported by `lsof` rarely matches the Homebrew service
/// formula (e.g. `postgres` → `postgresql@16`). Add new listeners here.
public enum BrewServiceNameMapping {
    public static let table: [String: String] = [
        "postgres": "postgresql@16",
        "redis-server": "redis",
        "mysqld": "mysql",
        "httpd": "httpd",
        "nginx": "nginx"
    ]

    public static func serviceName(for processName: String) throws -> String {
        guard let name = table[processName] else {
            throw KillEngineError.validationFailure(reason: .unmappedBrewProcess(processName: processName))
        }
        return name
    }
}
