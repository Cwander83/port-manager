import Foundation

public struct MockPortScanner: PortScanner {
    public init() {}

    public func scan() throws -> [PortItem] {
        [
            PortItem(
                port: 3000,
                address: "127.0.0.1",
                pid: 12345,
                processName: "node",
                kind: .node,
                label: "myshop",
                subtitle: "next dev",
                ramBytes: 128 * 1024 * 1024,
                isZombie: false
            ),
            PortItem(
                port: 5432,
                address: "127.0.0.1",
                pid: 23456,
                processName: "postgres",
                kind: .brew,
                label: "postgres",
                subtitle: "brew service",
                ramBytes: 64 * 1024 * 1024,
                isZombie: false
            ),
            PortItem(
                port: 8080,
                address: "0.0.0.0",
                pid: 34567,
                processName: "docker",
                kind: .docker,
                label: "myapp-container",
                subtitle: "docker",
                ramBytes: 210 * 1024 * 1024,
                isZombie: false
            ),
            PortItem(
                port: 8081,
                address: "127.0.0.1",
                pid: 45678,
                processName: "node",
                kind: .node,
                label: "3d",
                subtitle: "orphaned node",
                ramBytes: Int64(943_719),
                isZombie: true,
                startedAt: Date().addingTimeInterval(-3 * 24 * 60 * 60)
            ),
            PortItem(
                port: 11434,
                address: "127.0.0.1",
                pid: 56789,
                processName: "ollama",
                kind: .ollama,
                label: "ollama",
                subtitle: "llama3:70b loaded",
                ramBytes: Int64(4.2 * 1024 * 1024 * 1024),
                isZombie: false
            ),
            PortItem(
                port: 5173,
                address: "127.0.0.1",
                pid: 67890,
                processName: "node",
                kind: .node,
                label: "portfolio",
                subtitle: "vite",
                ramBytes: 86 * 1024 * 1024,
                isZombie: false
            )
        ]
    }
}
