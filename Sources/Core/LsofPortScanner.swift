import Foundation

/// Real scanner that runs `/usr/sbin/lsof` and parses the result.
///
/// Execution follows the exec contract in `PortScanner` and ADR-001 §7:
/// - absolute path (`/usr/sbin/lsof`)
/// - argv array, no shell
/// - no `PATH` lookup
/// - timeout and cancellation support via the injectable `ProcessRunner`
public struct LsofPortScanner: PortScanner {
    public static let lsofPath = "/usr/sbin/lsof"
    public static let lsofTimeout: TimeInterval = 5.0

    private let runner: any ProcessRunner
    public let provider: any ProcessInfoProvider

    public init(
        runner: any ProcessRunner = RealProcessRunner(),
        provider: any ProcessInfoProvider = RealProcessInfoProvider()
    ) {
        self.runner = runner
        self.provider = provider
    }

    public func scan() async throws -> [PortItem] {
        let result = try await runner.run(
            executableURL: URL(fileURLWithPath: Self.lsofPath),
            arguments: ["-iTCP", "-sTCP:LISTEN", "-P", "-n"],
            timeout: Self.lsofTimeout
        )

        if result.timedOut {
            throw LsofError.timedOut
        }

        // lsof exits 1 with no output when there are no matching listeners.
        // If it exits non-zero but still printed rows, parse the rows (e.g. stale
        // NFS warning) and only throw if there is no usable output.
        let trimmedOutput = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.status == 1, trimmedOutput.isEmpty {
            return []
        }

        if result.status != 0, trimmedOutput.isEmpty {
            let detail = result.stderr?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw LsofError.processFailed(status: result.status, stderr: detail)
        }

        return parseLsofOutput(result.output)
    }

    /// Test-only entry point that parses a captured lsof output without spawning a process.
    func parse(_ output: String) -> [PortItem] {
        parseLsofOutput(output)
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

            guard let parsed = parseRow(line),
                  (1...65_535).contains(parsed.port) else {
                continue
            }

            let key = "\(parsed.pid):\(parsed.port):\(parsed.address)"
            guard seen.insert(key).inserted else { continue }

            let metadata = metadataCache[parsed.pid] ?? provider.metadata(for: parsed.pid)
            metadataCache[parsed.pid] = metadata

            items.append(makeItem(
                processName: parsed.command,
                pid: parsed.pid,
                address: parsed.address,
                port: parsed.port,
                metadata: metadata
            ))
        }

        return items
    }

    private struct ParsedRow {
        let command: String
        let pid: pid_t
        let address: String
        let port: Int
    }

    /// Parses the stable trailing end of an lsof row.
    ///
    /// lsof output is fixed-width but fields can be blank. The reliable parts are:
    /// - command: first whitespace-delimited token
    /// - pid: second token
    /// - `(LISTEN)`: last token
    /// - address:port: second-to-last token (`127.0.0.1:3000`, `[::]:3000`, `*:3000`)
    private func parseRow(_ line: String) -> ParsedRow? {
        let tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard tokens.count >= 4,
              tokens.last == "(LISTEN)" else { return nil }

        let nameToken = tokens[tokens.count - 2]
        guard let (address, port) = parseAddressPort(nameToken) else { return nil }
        guard let pid = pid_t(tokens[1]) else { return nil }

        return ParsedRow(command: tokens[0], pid: pid, address: address, port: port)
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
        let kind = kind(for: processName, path: metadata.executablePath)
        let isZombie = metadata.parentPID == 1 && kind == .node

        return PortItem(
            port: port,
            address: address,
            pid: pid,
            processName: processName,
            kind: kind,
            label: label(for: metadata.executablePath, processName: processName),
            subtitle: subtitle(for: kind, processName: processName),
            ramBytes: metadata.ramBytes,
            isZombie: isZombie,
            startedAt: metadata.startedAt,
            processStartTime: metadata.startedAt,
            localAddress: address
        )
    }

    /// Known docker process names, including lsof's truncated `com.docke` and `docker-pr`.
    private var dockerProcessNames: Set<String> {
        ["docker", "com.docker.backend", "com.docke", "docker-proxy", "docker-pr"]
    }

    private func kind(for processName: String, path: String?) -> ListenerKind {
        let lower = processName.lowercased()

        switch lower {
        case "node", "vite", "esbuild":
            return .node
        case _ where dockerProcessNames.contains(lower):
            return .docker
        case "ollama":
            return .ollama
        default:
            break
        }

        // Path-root fallback: only brew-related processes installed under homebrew
        // qualify as `.brew`. This prevents Postgres.app in /Applications from being
        // misclassified while still catching homebrew postgres/redis/mysql on both Apple
        // Silicon and Intel/Rosetta paths.
        let pathLower = path?.lowercased() ?? ""
        let isUnderHomebrew = pathLower.contains("/cellar/")
            || pathLower.contains("/homebrew/")
            || pathLower.hasPrefix("/usr/local/opt/")
            || pathLower.hasPrefix("/usr/local/bin/")
        if isUnderHomebrew {
            switch lower {
            case _ where lower.hasPrefix("postgres") || lower.hasPrefix("redis") || lower.hasPrefix("mysql"):
                return .brew
            default:
                break
            }
        }

        return .other
    }

    /// Picks a project label from the executable path.
    ///
    /// We walk the path components from the end and choose the first component that looks
    /// meaningful (not `bin`, `node_modules`, `.bin`, `MacOS`, etc.). This is pragmatic and
    /// works for most dev setups: `/Users/me/Codebases/myshop/node_modules/.bin/node` →
    /// `myshop`. It is intentionally simple; it cannot resolve a node script's actual repo
    /// when the executable itself is a global `node`, and it ignores symlinks.
    ///
    /// Components ending in `.app` are skipped so `Slack.app` is never used as a project label.
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
            // Skip app bundles.
            if lower.hasSuffix(".app") {
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
            "com.docker.backend", "docker", "docker-proxy"
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
    case processFailed(status: Int32, stderr: String?)
    case outputDecodingFailed
    case timedOut
}

extension LsofError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .processFailed(let status, let stderr):
            var message = "lsof exited with status \(status)"
            if let stderr = stderr, !stderr.isEmpty {
                message += ": \(stderr)"
            }
            return message
        case .outputDecodingFailed:
            return "Could not decode lsof output"
        case .timedOut:
            return "lsof timed out"
        }
    }
}
