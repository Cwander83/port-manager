import Foundation

struct BrewServiceRule: KillRule {
    private let runner: CommandRunner
    private let primaryPath: String
    private let fallbackPath: String
    private let launchctlPath: String

    init(
        runner: CommandRunner,
        primaryPath: String = "/opt/homebrew/bin/brew",
        fallbackPath: String = "/usr/local/bin/brew",
        launchctlPath: String = "/bin/launchctl"
    ) {
        self.runner = runner
        self.primaryPath = primaryPath
        self.fallbackPath = fallbackPath
        self.launchctlPath = launchctlPath
    }

    func canHandle(_ item: PortItem) -> Bool {
        item.kind == .brew
    }

    func makeAction(_ item: PortItem) async throws -> KillAction {
        let brewPath = resolveBrewPath()
        guard FileManager.default.fileExists(atPath: brewPath) else {
            throw KillEngineError.brewBinaryMissing
        }

        let serviceName = try await resolveServiceName(for: item, brewPath: brewPath)

        return .brewStop(
            serviceName: serviceName,
            commandDescription: "brew services stop \(serviceName)",
            executable: brewPath
        )
    }

    private func resolveServiceName(for item: PortItem, brewPath: String) async throws -> String {
        let servicesResult = try await runner.run(
            executable: brewPath,
            arguments: ["services", "list"]
        )
        guard servicesResult.exitCode == 0 else {
            throw KillEngineError.commandListUnavailable
        }
        let services = parseBrewServicesList(servicesResult.stdout)

        let launchctlResult = try await runner.run(
            executable: launchctlPath,
            arguments: ["list"]
        )
        guard launchctlResult.exitCode == 0 else {
            throw KillEngineError.commandListUnavailable
        }
        let pidMap = parseLaunchctlList(launchctlResult.stdout)

        // Exact PID match is the most reliable signal.
        if let pidMatch = pidMap[item.pid], pidMatch.count == 1 {
            return pidMatch[0]
        }

        // Fall back to prefix-matching the process name against running brew services.
        let prefix = BrewServiceNameMapping.prefix(for: item.processName)
        guard !prefix.isEmpty else {
            throw KillEngineError.validationFailure(reason: .unmappedBrewProcess(processName: item.processName))
        }
        let candidates = services.filter { $0.status == "started" && $0.name.hasPrefix(prefix) }

        guard !candidates.isEmpty else {
            throw KillEngineError.validationFailure(reason: .unmappedBrewProcess(processName: item.processName))
        }
        guard candidates.count == 1 else {
            throw KillEngineError.validationFailure(reason: .ambiguousBrewService)
        }
        return candidates[0].name
    }

    private func resolveBrewPath() -> String {
        if FileManager.default.fileExists(atPath: primaryPath) {
            return primaryPath
        }
        return fallbackPath
    }
}

private struct BrewService {
    let name: String
    let status: String
}

private func parseBrewServicesList(_ output: String) -> [BrewService] {
    var services: [BrewService] = []
    let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
    guard let regex = try? NSRegularExpression(pattern: #"^(\S+)\s+(\S+)"#) else {
        return []
    }
    for line in lines {
        let nsLine = String(line)
        let range = NSRange(nsLine.startIndex..., in: nsLine)
        guard let match = regex.firstMatch(in: nsLine, options: [], range: range) else { continue }
        let nameRange = Range(match.range(at: 1), in: nsLine)!
        let statusRange = Range(match.range(at: 2), in: nsLine)!
        services.append(BrewService(
            name: String(nsLine[nameRange]),
            status: String(nsLine[statusRange])
        ))
    }
    return services
}

private func parseLaunchctlList(_ output: String) -> [pid_t: [String]] {
    var map: [pid_t: [String]] = [:]
    let prefix = "homebrew.mxcl."
    for line in output.split(separator: "\n", omittingEmptySubsequences: true).dropFirst() {
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { continue }
        guard let pid = Int32(parts[0]) else { continue }
        guard pid > 0 else { continue }
        let label = String(parts[2])
        guard label.hasPrefix(prefix) else { continue }
        let name = String(label.dropFirst(prefix.count))
        map[pid, default: []].append(name)
    }
    return map
}

/// Process name to expected Homebrew service name prefix.
///
/// The executable name reported by `lsof` rarely matches the formula
/// (e.g. `postgres` → `postgresql@16`). These prefixes are matched against
/// the live `brew services list` output so version suffixes (`@14`..`@17`)
/// resolve automatically.
public enum BrewServiceNameMapping {
    public static let table: [String: String] = [
        "postgres": "postgresql",
        "redis-server": "redis",
        "mysqld": "mysql",
        "httpd": "httpd",
        "nginx": "nginx",
        "mongod": "mongodb"
    ]

    public static func prefix(for processName: String) -> String {
        table[processName] ?? processName
    }
}
