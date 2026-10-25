import Foundation

/// Real scanner that shells out to `/usr/sbin/lsof` and parses the result.
///
/// Execution follows the exec contract in `PortScanner` and ADR-001 §7:
/// - absolute path (`/usr/sbin/lsof`)
/// - argv array, no shell
/// - no `PATH` lookup
public struct LsofPortScanner: PortScanner {
    public let provider: any ProcessInfoProvider

    public init(provider: any ProcessInfoProvider = RealProcessInfoProvider()) {
        self.provider = provider
    }

    public func scan() throws -> [PortItem] {
        let output = try runLsof()
        return parseLsofOutput(output)
    }

    /// Test-only entry point that parses a captured lsof output without spawning a process.
    func parse(_ output: String) -> [PortItem] {
        parseLsofOutput(output)
    }

    // MARK: - lsof execution

    private func runLsof() throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-iTCP", "-sTCP:LISTEN", "-P", "-n"]

        let pipe = Pipe()
        task.standardOutput = pipe

        try task.run()
        task.waitUntilExit()

        guard task.terminationStatus == 0 else {
            throw LsofError.processFailed(status: task.terminationStatus)
        }

        guard let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) else {
            throw LsofError.outputDecodingFailed
        }

        return output
    }

    // MARK: - Parsing

    private func parseLsofOutput(_ output: String) -> [PortItem] {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)

        var afterHeader = false
        var seen = Set<String>()
        var items: [PortItem] = []
        var metadataCache: [pid_t: ProcessMetadata] = [:]

        for line in lines {
            if line.hasPrefix("COMMAND") {
                afterHeader = true
                continue
            }

            guard afterHeader else { continue }

            let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
            guard tokens.count >= 10,
                  tokens.last == "(LISTEN)",
                  let pid = pid_t(String(tokens[1])) else {
                continue
            }

            let processName = String(tokens[0])
            let nameToken = String(tokens[tokens.count - 2])

            guard let (address, port) = parseAddressPort(nameToken) else { continue }

            let key = "\(pid):\(port):\(address)"
            guard seen.insert(key).inserted else { continue }

            let metadata = metadataCache[pid] ?? provider.metadata(for: pid)
            metadataCache[pid] = metadata

            items.append(makeItem(
                processName: processName,
                pid: pid,
                address: address,
                port: port,
                metadata: metadata
            ))
        }

        return items
    }

    private func parseAddressPort(_ token: String) -> (address: String, port: Int)? {
        guard let colon = token.lastIndex(of: ":") else { return nil }

        let address = String(token[..<colon])
        let portStart = token.index(after: colon)
        let portString = String(token[portStart...])

        guard let port = Int(portString), (1...65_535).contains(port) else { return nil }
        return (address, port)
    }

    // MARK: - Enrichment

    private func makeItem(
        processName: String,
        pid: pid_t,
        address: String,
        port: Int,
        metadata: ProcessMetadata
    ) -> PortItem {
        let kind = kind(for: processName)
        return PortItem(
            port: port,
            address: address,
            pid: pid,
            processName: processName,
            kind: kind,
            label: label(for: metadata.executablePath, processName: processName),
            subtitle: subtitle(for: kind, processName: processName),
            ramBytes: metadata.ramBytes,
            isZombie: metadata.parentPID == 1,
            startedAt: metadata.startedAt
        )
    }

    private func kind(for processName: String) -> ListenerKind {
        let lower = processName.lowercased()

        switch lower {
        case "node", "vite", "esbuild":
            return .node
        case _ where lower.hasPrefix("com.docker") || lower.hasPrefix("com.docke") || lower == "docker":
            return .docker
        case "ollama":
            return .ollama
        case _ where lower.hasPrefix("postgres") || lower.hasPrefix("redis") || lower.hasPrefix("mysql"):
            return .brew
        default:
            return .other
        }
    }

    /// Picks a project label from the executable path.
    ///
    /// We walk the path components from the end and choose the first component that looks
    /// meaningful (not `bin`, `node_modules`, `.bin`, `MacOS`, etc.). This is pragmatic and
    /// works for most dev setups: `/Users/me/Codebases/myshop/node_modules/.bin/node` →
    /// `myshop`. It is intentionally simple; it cannot resolve a node script's actual repo
    /// when the executable itself is a global `node`, and it ignores symlinks.
    private func label(for path: String?, processName: String) -> String {
        guard let path = path, !path.isEmpty else { return processName }

        let components = path.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return processName }

        var reversed = Array(components.reversed())

        // The final component is the executable itself; skip it when it matches a known binary name.
        if let executable = reversed.first,
           executablesToSkip.contains(executable.lowercased()) {
            reversed.removeFirst()
        }

        for component in reversed {
            let lower = component.lowercased()
            if lower.isEmpty || meaninglessPathComponents.contains(lower) {
                continue
            }
            // Skip UUID-shaped bundle IDs/Frameworks directories.
            if component.count == 36, component.filter({ $0 == "-" }).count == 4 {
                continue
            }
            return component
        }

        return processName
    }

    private var executablesToSkip: Set<String> {
        [
            "node", "vite", "esbuild",
            "ollama",
            "postgres", "redis-server", "mysqld", "mysql",
            "python", "python3",
            "com.docker.backend", "docker"
        ]
    }

    private var meaninglessPathComponents: Set<String> {
        [
            "", ".", "..",
            "bin", "sbin", "usr", "local", "opt", "homebrew", "cellar",
            "node_modules", ".bin",
            "contents", "macos", "versions", "frameworks", "loginitems", "library",
            "applications", "docker.app", "ollama.app"
        ]
    }

    private func subtitle(for kind: ListenerKind, processName: String) -> String {
        switch kind {
        case .brew: return "brew service"
        case .docker: return "docker"
        default: return processName
        }
    }
}

private enum LsofError: Error {
    case processFailed(status: Int32)
    case outputDecodingFailed
}

extension LsofError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .processFailed(let status):
            return "lsof exited with status \(status)"
        case .outputDecodingFailed:
            return "Could not decode lsof output"
        }
    }
}
