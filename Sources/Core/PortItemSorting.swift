import Foundation

public extension [PortItem] {
    func sortedForDisplay() -> [PortItem] {
        sorted {
            if $0.isZombie != $1.isZombie {
                return !$0.isZombie
            }
            if $0.port != $1.port {
                return $0.port < $1.port
            }
            return $0.id < $1.id
        }
    }
}

public func nextFreePort(used: Set<Int>, startingAt: Int = 3000) -> Int? {
    guard (1...65_535).contains(startingAt) else { return nil }
    var candidate = startingAt
    while used.contains(candidate) {
        candidate += 1
        guard candidate <= 65_535 else { return nil }
    }
    return candidate
}
