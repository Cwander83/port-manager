import Foundation

public protocol PortScanner: Sendable {
    func scan() throws -> [PortItem]
}
