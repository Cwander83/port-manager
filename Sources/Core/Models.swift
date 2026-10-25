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

    // Additive fields from parallel kill-engine branch; kept with defaults for clean merge.
    public let processStartTime: Date?
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

extension PortItem: Equatable {
    public static func == (lhs: PortItem, rhs: PortItem) -> Bool {
        lhs.id == rhs.id
            && lhs.pid == rhs.pid
            && lhs.port == rhs.port
            && lhs.address == rhs.address
            && lhs.processName == rhs.processName
            && lhs.kind == rhs.kind
            && lhs.label == rhs.label
            && lhs.subtitle == rhs.subtitle
            && lhs.ramBytes == rhs.ramBytes
            && lhs.isZombie == rhs.isZombie
            && lhs.startedAt == rhs.startedAt
            && lhs.processStartTime == rhs.processStartTime
            && lhs.localAddress == rhs.localAddress
    }
}
