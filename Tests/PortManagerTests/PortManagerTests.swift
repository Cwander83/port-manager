import XCTest
@testable import Core

final class PortManagerTests: XCTestCase {
    func testMockPortScannerReturnsSixFixtures() throws {
        let scanner = MockPortScanner()
        let items = try scanner.scan()

        XCTAssertEqual(items.count, 6)
        XCTAssertEqual(items.map(\.port), [3000, 5432, 8080, 8081, 11434, 5173])
        XCTAssertEqual(items.map(\.kind), [.node, .brew, .docker, .node, .ollama, .node])
        XCTAssertEqual(items.map(\.isZombie), [false, false, false, true, false, false])
    }

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

    func testPortItemIdUniquenessForDualStack() {
        let ipv4 = PortItem(port: 3000, pid: 12345, processName: "node", kind: .node, label: "a", subtitle: "", ramBytes: 0, isZombie: false)
        let ipv6 = PortItem(port: 3000, pid: 12346, processName: "node", kind: .node, label: "a", subtitle: "", ramBytes: 0, isZombie: false)
        XCTAssertEqual(ipv4.id, "12345:3000")
        XCTAssertEqual(ipv6.id, "12346:3000")
        XCTAssertNotEqual(ipv4.id, ipv6.id)
    }

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
}


