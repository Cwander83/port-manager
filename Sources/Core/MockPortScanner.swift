import Foundation

public struct MockPortScanner: PortScanner {
    public init() {}

    public func scan() throws -> [PortItem] {
        [
            PortItem(
                port: 3000,
                pid: 12345,
                processName: "node",
                kind: .node,
                label: "myshop",
                ramBytes: 128 * 1024 * 1024,
                isZombie: false
            ),
            PortItem(
                port: 5432,
                pid: 23456,
                processName: "postgres",
                kind: .brew,
                label: "postgres",
                ramBytes: 64 * 1024 * 1024,
                isZombie: false
            ),
            PortItem(
                port: 8080,
                pid: 34567,
                processName: "docker",
                kind: .docker,
                label: "myapp-container",
                ramBytes: 210 * 1024 * 1024,
                isZombie: false
            ),
            PortItem(
                port: 8081,
                pid: 45678,
                processName: "node",
                kind: .node,
                label: "3d",
                ramBytes: 900 * 1024,
                isZombie: true,
                startedAt: Date().addingTimeInterval(-3 * 24 * 60 * 60)
            ),
            PortItem(
                port: 11434,
                pid: 56789,
                processName: "ollama",
                kind: .ollama,
                label: "llama3:70b",
                ramBytes: 4_200 * 1024 * 1024,
                isZombie: false
            ),
            PortItem(
                port: 5173,
                pid: 67890,
                processName: "node",
                kind: .node,
                label: "portfolio",
                ramBytes: 86 * 1024 * 1024,
                isZombie: false
            )
        ]
    }
}
