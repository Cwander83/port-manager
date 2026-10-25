import Foundation

public extension [PortItem] {
    func sortedForDisplay() -> [PortItem] {
        sorted {
            if $0.isZombie != $1.isZombie {
                return !$0.isZombie
            }
            return $0.port < $1.port
        }
    }
}
