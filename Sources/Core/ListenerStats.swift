import Foundation

/// Deduped aggregate stats for a list of listeners.
public struct ListenerStats: Sendable, Equatable {
    /// Number of unique processes (by pid) in the list.
    public let processCount: Int
    /// Total RAM held by those unique processes.
    public let totalRAM: Int64

    public init(processCount: Int, totalRAM: Int64) {
        self.processCount = processCount
        self.totalRAM = totalRAM
    }
}

public extension [PortItem] {
    /// Computes deduped stats keyed by PID.
    ///
    /// Per-address rows can cause one PID to appear multiple times; this keeps the first
    /// `ramBytes` per PID so RAM and process count are not double-counted in the UI.
    func listenerStats() -> ListenerStats {
        var seen = Set<pid_t>()
        var totalRAM: Int64 = 0

        for item in self {
            if seen.insert(item.pid).inserted {
                totalRAM += item.ramBytes ?? 0
            }
        }

        return ListenerStats(processCount: seen.count, totalRAM: totalRAM)
    }
}
