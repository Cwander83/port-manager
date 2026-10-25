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
    public var id: Int { port }

    public let port: Int
    public let pid: pid_t
    public let processName: String
    public let kind: ListenerKind
    public let label: String
    public let ramBytes: Int64?
    public let isZombie: Bool
    public let startedAt: Date?

    public init(
        port: Int,
        pid: pid_t,
        processName: String,
        kind: ListenerKind,
        label: String,
        ramBytes: Int64?,
        isZombie: Bool,
        startedAt: Date? = nil
    ) {
        self.port = port
        self.pid = pid
        self.processName = processName
        self.kind = kind
        self.label = label
        self.ramBytes = ramBytes
        self.isZombie = isZombie
        self.startedAt = startedAt
    }
}
