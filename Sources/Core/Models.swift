import Foundation

public enum ListenerKind: String, CaseIterable, Sendable {
    case node
    case docker
    case ollama
    case brew
    case other

    public var displayName: String {
        switch self {
        case .node: return "node"
        case .docker: return "docker"
        case .ollama: return "ollama"
        case .brew: return "brew"
        case .other: return "other"
        }
    }
}

public struct PortItem: Sendable, Identifiable {
    public var id: String { "\(pid):\(port):\(address)" }

    public let port: Int
    public let address: String
    public let pid: pid_t
    public let processName: String
    public let kind: ListenerKind
    public let label: String
    public let subtitle: String
    public let ramBytes: Int64?
    public let isZombie: Bool
    public let startedAt: Date?
    /// When the scanner captured this process, for pid-reuse detection.
    public let processStartTime: Date?
    /// Local bind address reported by the scanner (e.g. `127.0.0.1`, `0.0.0.0`, `[::]`).
    public let localAddress: String?

    public init(
        port: Int,
        address: String = "0.0.0.0",
        pid: pid_t,
        processName: String,
        kind: ListenerKind,
        label: String,
        subtitle: String,
        ramBytes: Int64?,
        isZombie: Bool,
        startedAt: Date? = nil,
        processStartTime: Date? = nil,
        localAddress: String? = nil
    ) {
        self.port = port
        self.address = address
        self.pid = pid
        self.processName = processName
        self.kind = kind
        self.label = label
        self.subtitle = subtitle
        self.ramBytes = ramBytes
        self.isZombie = isZombie
        self.startedAt = startedAt
        self.processStartTime = processStartTime
        self.localAddress = localAddress
    }

    public func ageLabel(now: Date = Date()) -> String {
        guard let startedAt else { return "unknown age" }
        let seconds = now.timeIntervalSince(startedAt)
        guard seconds > 0 else { return "just now" }

        let minutes = seconds / 60
        let hours = minutes / 60
        let days = hours / 24

        if days >= 1 {
            return String(format: "%.0fd", days)
        } else if hours >= 1 {
            return String(format: "%.0fh", hours)
        } else if minutes >= 1 {
            return String(format: "%.0fm", minutes)
        } else {
            return String(format: "%.0fs", seconds)
        }
    }
}

/// Semantics for additive fields (mirrors kill-engine branch usage):
/// - `processStartTime`: process `pbi_start_tvsec` (macOS `proc_pidinfo`), i.e. when the PID launched.
/// - `localAddress`: raw lsof `NAME` column host part only (e.g. `*`, `[::1]`, `127.0.0.1`).
extension PortItem: Equatable {}
