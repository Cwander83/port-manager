import Combine
import Foundation
import XCTest
@testable import Core
@testable import PortManager

final class PortManagerTests: XCTestCase {
    // MARK: - Mock scanner

    func testMockPortScannerReturnsSixFixtures() throws {
        let scanner = MockPortScanner()
        let items = try scanner.scan()

        XCTAssertEqual(items.count, 6)
        XCTAssertEqual(items.map(\.port), [3000, 5432, 8080, 8081, 11434, 5173])
        XCTAssertEqual(items.map(\.kind), [.node, .brew, .docker, .node, .ollama, .node])
        XCTAssertEqual(items.map(\.isZombie), [false, false, false, true, false, false])
    }

    // MARK: - Sorting

    func testSortedForDisplayPutsZombieLast() throws {
        let scanner = MockPortScanner()
        let items = try scanner.scan().sortedForDisplay()

        XCTAssertEqual(items.count, 6)
        XCTAssertEqual(items.last?.port, 8081)
        XCTAssertTrue(items.last?.isZombie == true)

        let zombieIndex = items.firstIndex { $0.isZombie }
        let nonZombieCount = items.filter { !$0.isZombie }.count
        XCTAssertEqual(zombieIndex, nonZombieCount)
    }

    func testSortedForDisplayTieBreaksZombiesByPort() {
        let items = [
            PortItem(port: 8081, pid: 1, processName: "node", kind: .node, label: "a", subtitle: "", ramBytes: 0, isZombie: true),
            PortItem(port: 8080, pid: 2, processName: "node", kind: .node, label: "b", subtitle: "", ramBytes: 0, isZombie: true),
            PortItem(port: 3000, pid: 3, processName: "node", kind: .node, label: "c", subtitle: "", ramBytes: 0, isZombie: false)
        ]
        let sorted = items.sortedForDisplay()
        XCTAssertEqual(sorted.map(\.port), [3000, 8080, 8081])
    }

    // MARK: - Identity / dual-stack (N3)

    func testPortItemIdUniquenessForDualStack() {
        let ipv4 = PortItem(port: 3000, address: "127.0.0.1", pid: 12345, processName: "node", kind: .node, label: "a", subtitle: "", ramBytes: 0, isZombie: false)
        let ipv6 = PortItem(port: 3000, address: "[::1]", pid: 12345, processName: "node", kind: .node, label: "a", subtitle: "", ramBytes: 0, isZombie: false)

        XCTAssertEqual(ipv4.id, "12345:3000:127.0.0.1")
        XCTAssertEqual(ipv6.id, "12345:3000:[::1]")
        XCTAssertNotEqual(ipv4.id, ipv6.id)
        XCTAssertNotEqual(ipv4, ipv6)
        // Same PID + port with different addresses = two distinct listeners.
        XCTAssertEqual(ipv4.pid, ipv6.pid)
        XCTAssertEqual(ipv4.port, ipv6.port)
    }

    // MARK: - Utilities

    func testNextFreePort() {
        XCTAssertEqual(nextFreePort(used: [3000, 3001]), 3002)
        XCTAssertEqual(nextFreePort(used: [3000], startingAt: 3000), 3001)
        XCTAssertNil(nextFreePort(used: Set(3000...65_535)))
        XCTAssertNil(nextFreePort(used: [], startingAt: 70_000))
    }

    func testAgeLabel() {
        let now = Date()
        let threeDays = now.addingTimeInterval(-3 * 24 * 60 * 60)
        let zombie = PortItem(port: 8081, pid: 1, processName: "node", kind: .node, label: "a", subtitle: "", ramBytes: 0, isZombie: true, startedAt: threeDays)
        XCTAssertEqual(zombie.ageLabel(now: now), "3d")

        let oneHour = now.addingTimeInterval(-60 * 60)
        let recent = PortItem(port: 8082, pid: 2, processName: "node", kind: .node, label: "b", subtitle: "", ramBytes: 0, isZombie: false, startedAt: oneHour)
        XCTAssertEqual(recent.ageLabel(now: now), "1h")

        let noDate = PortItem(port: 8083, pid: 3, processName: "node", kind: .node, label: "c", subtitle: "", ramBytes: 0, isZombie: false)
        XCTAssertEqual(noDate.ageLabel(now: now), "unknown age")
    }

    func testFormatBytes() {
        XCTAssertEqual(Int64(943_719).formatBytes(), "0.9 MB")
        XCTAssertEqual(Int64(128 * 1024 * 1024).formatBytes(), "128.0 MB")
        XCTAssertEqual(Int64(4.2 * 1024 * 1024 * 1024).formatBytes(), "4.2 GB")
        XCTAssertEqual(Int64(512).formatBytes(), "512 B")
    }

    // MARK: - lsof fixture parsing

    func testLsofMixedFixtureParsesCorrectly() throws {
        let date = Date(timeIntervalSince1970: 1_000_000)
        let scanner = LsofPortScanner(provider: StubProcessInfoProvider(referenceDate: date))
        let output = try fixture(named: "lsof-mixed.txt")
        let items = scanner.parse(output).sortedForDisplay()

        let expected: [PortItem] = [
            PortItem(
                port: 3000, address: "127.0.0.1", pid: 12345, processName: "node",
                kind: .node, label: "myshop", subtitle: "node",
                ramBytes: 128 * 1024 * 1024, isZombie: false, startedAt: date
            ),
            PortItem(
                port: 5432, address: "127.0.0.1", pid: 23456, processName: "postgres",
                kind: .brew, label: "postgres", subtitle: "brew service",
                ramBytes: 64 * 1024 * 1024, isZombie: false, startedAt: date
            ),
            PortItem(
                port: 6379, address: "127.0.0.1", pid: 34567, processName: "redis-ser",
                kind: .brew, label: "redis", subtitle: "brew service",
                ramBytes: 32 * 1024 * 1024, isZombie: false, startedAt: date
            ),
            PortItem(
                port: 11434, address: "127.0.0.1", pid: 45678, processName: "ollama",
                kind: .ollama, label: "ollama", subtitle: "ollama",
                ramBytes: Int64(4.2 * 1024 * 1024 * 1024), isZombie: false, startedAt: date
            ),
            PortItem(
                port: 5000, address: "0.0.0.0", pid: 56789, processName: "Python",
                kind: .other, label: "backend", subtitle: "Python",
                ramBytes: 12 * 1024 * 1024, isZombie: false, startedAt: date
            ),
            PortItem(
                port: 8081, address: "127.0.0.1", pid: 99999, processName: "node",
                kind: .node, label: "node", subtitle: "node",
                ramBytes: 1 * 1024 * 1024, isZombie: true, startedAt: date
            )
        ]

        XCTAssertEqual(items, expected.sortedForDisplay())
    }

    func testLsofDualStackFixtureDeduplicatesSameAddressRows() throws {
        let date = Date(timeIntervalSince1970: 2_000_000)
        let scanner = LsofPortScanner(provider: StubProcessInfoProvider(referenceDate: date))
        let output = try fixture(named: "lsof-dualstack.txt")
        let items = scanner.parse(output).sortedForDisplay()

        XCTAssertEqual(items.count, 2)

        let ipv4 = items.first { $0.address == "127.0.0.1" }
        let ipv6 = items.first { $0.address == "[::1]" }
        XCTAssertNotNil(ipv4)
        XCTAssertNotNil(ipv6)
        XCTAssertEqual(ipv4?.pid, 11111)
        XCTAssertEqual(ipv6?.pid, 11111)
        XCTAssertEqual(ipv4?.port, 3000)
        XCTAssertEqual(ipv6?.port, 3000)
    }

    func testLsofDockerFixtureDetectsDockerKind() throws {
        let date = Date(timeIntervalSince1970: 3_000_000)
        let scanner = LsofPortScanner(provider: StubProcessInfoProvider(referenceDate: date))
        let output = try fixture(named: "lsof-docker.txt")
        let items = scanner.parse(output).sortedForDisplay()

        XCTAssertEqual(items.count, 2)

        let docker = items.first { $0.port == 8080 }
        let node = items.first { $0.port == 3001 }
        XCTAssertEqual(docker?.kind, ListenerKind.docker)
        XCTAssertEqual(docker?.processName, "com.docke")
        XCTAssertEqual(node?.kind, ListenerKind.node)
    }

    func testLsofEmptyOutputReturnsEmpty() {
        let scanner = LsofPortScanner(provider: StubProcessInfoProvider(referenceDate: Date()))
        XCTAssertTrue(scanner.parse("").isEmpty)
        XCTAssertTrue(scanner.parse("\n").isEmpty)
        XCTAssertTrue(scanner.parse("COMMAND     PID USER...").isEmpty)
    }

    // MARK: - PortStore scan scheduling (N1)

    @MainActor
    func testScanDropTickDoesNotCancelInFlightScan() throws {
        let item = PortItem(
            port: 4000, address: "127.0.0.1", pid: 777, processName: "node",
            kind: .node, label: "test", subtitle: "node",
            ramBytes: 1 * 1024 * 1024, isZombie: false
        )
        let slow = SlowPortScanner(delay: 0.2, result: [item])
        let store = PortStore(scanner: slow)

        store.startScanning(interval: 10)
        store.tick() // should drop because first scan is still in-flight

        let expectation = expectation(description: "listeners updated")
        let cancellable = store.$listeners
            .dropFirst()
            .sink { _ in expectation.fulfill() }

        wait(for: [expectation], timeout: 1.0)
        cancellable.cancel()

        XCTAssertEqual(slow.invocations, 1)
        XCTAssertEqual(store.listeners, [item])
    }
}

// MARK: - Test helpers

private struct StubProcessInfoProvider: ProcessInfoProvider {
    let referenceDate: Date

    func metadata(for pid: pid_t) -> ProcessMetadata {
        switch pid {
        case 12345:
            return ProcessMetadata(
                executablePath: "/Users/dev/Codebases/myshop/node_modules/.bin/node",
                ramBytes: 128 * 1024 * 1024,
                parentPID: 100,
                startedAt: referenceDate
            )
        case 23456:
            return ProcessMetadata(
                executablePath: "/opt/homebrew/opt/postgres/bin/postgres",
                ramBytes: 64 * 1024 * 1024,
                parentPID: 200,
                startedAt: referenceDate
            )
        case 34567:
            return ProcessMetadata(
                executablePath: "/opt/homebrew/opt/redis/bin/redis-server",
                ramBytes: 32 * 1024 * 1024,
                parentPID: 300,
                startedAt: referenceDate
            )
        case 45678:
            return ProcessMetadata(
                executablePath: "/Users/dev/ollama/Ollama",
                ramBytes: Int64(4.2 * 1024 * 1024 * 1024),
                parentPID: 400,
                startedAt: referenceDate
            )
        case 56789:
            return ProcessMetadata(
                executablePath: "/Users/dev/Codebases/backend",
                ramBytes: 12 * 1024 * 1024,
                parentPID: 500,
                startedAt: referenceDate
            )
        case 99999:
            return ProcessMetadata(
                executablePath: "/usr/local/bin/node",
                ramBytes: 1 * 1024 * 1024,
                parentPID: 1,
                startedAt: referenceDate
            )
        case 11111:
            return ProcessMetadata(
                executablePath: "/Users/dev/Codebases/myshop/node_modules/.bin/node",
                ramBytes: 96 * 1024 * 1024,
                parentPID: 600,
                startedAt: referenceDate
            )
        case 98765:
            return ProcessMetadata(
                executablePath: "/Applications/Docker.app/Contents/MacOS/com.docker.backend",
                ramBytes: 210 * 1024 * 1024,
                parentPID: 700,
                startedAt: referenceDate
            )
        case 54321:
            return ProcessMetadata(
                executablePath: "/Users/dev/Codebases/portfolio/node_modules/.bin/node",
                ramBytes: 86 * 1024 * 1024,
                parentPID: 800,
                startedAt: referenceDate
            )
        default:
            return ProcessMetadata()
        }
    }
}

private final class SlowPortScanner: PortScanner, @unchecked Sendable {
    let delay: TimeInterval
    let result: [PortItem]
    private let lock = NSLock()
    private var _invocations = 0

    var invocations: Int {
        lock.withLock { _invocations }
    }

    init(delay: TimeInterval, result: [PortItem]) {
        self.delay = delay
        self.result = result
    }

    func scan() throws -> [PortItem] {
        lock.withLock { _invocations += 1 }
        Thread.sleep(forTimeInterval: delay)
        return result
    }
}

private func fixture(named name: String) throws -> String {
    let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let fixtureURL = testsDir
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/\(name)")
    return try String(contentsOf: fixtureURL, encoding: .utf8)
}
