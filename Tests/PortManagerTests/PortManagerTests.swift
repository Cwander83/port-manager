import Combine
import Foundation
import XCTest
@testable import Core
@testable import PortManager

final class PortManagerTests: XCTestCase {
    // MARK: - Mock scanner

    func testMockPortScannerReturnsSixFixtures() async throws {
        let scanner = MockPortScanner()
        let items = try await scanner.scan()

        XCTAssertEqual(items.count, 6)
        XCTAssertEqual(items.map(\.port), [3000, 5432, 8080, 8081, 11434, 5173])
        XCTAssertEqual(items.map(\.kind), [.node, .brew, .docker, .node, .ollama, .node])
        XCTAssertEqual(items.map(\.isZombie), [false, false, false, true, false, false])
    }

    // MARK: - Sorting

    func testSortedForDisplayPutsZombieLast() async throws {
        let scanner = MockPortScanner()
        let items = try await scanner.scan().sortedForDisplay()

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

    func testSortedForDisplayTieBreaksById() {
        let a = PortItem(port: 3000, address: "127.0.0.1", pid: 2, processName: "node", kind: .node, label: "a", subtitle: "", ramBytes: 0, isZombie: false)
        let b = PortItem(port: 3000, address: "[::1]", pid: 1, processName: "node", kind: .node, label: "b", subtitle: "", ramBytes: 0, isZombie: false)
        let sorted = [a, b].sortedForDisplay()
        XCTAssertEqual(sorted.map(\.id), [b.id, a.id])
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

    // MARK: - Listener stats (deduped by PID)

    func testListenerStatsDedupesDualStackByPID() {
        let items = [
            PortItem(port: 3000, address: "127.0.0.1", pid: 100, processName: "node", kind: .node, label: "a", subtitle: "", ramBytes: 100, isZombie: false),
            PortItem(port: 3000, address: "[::1]", pid: 100, processName: "node", kind: .node, label: "a", subtitle: "", ramBytes: 100, isZombie: false)
        ]
        let stats = items.listenerStats()
        XCTAssertEqual(stats.processCount, 1)
        XCTAssertEqual(stats.totalRAM, 100)
    }

    func testListenerStatsHandlesMissingRAM() {
        let items = [
            PortItem(port: 3000, pid: 1, processName: "a", kind: .node, label: "a", subtitle: "", ramBytes: nil, isZombie: false),
            PortItem(port: 3001, pid: 2, processName: "b", kind: .node, label: "b", subtitle: "", ramBytes: 512, isZombie: false)
        ]
        let stats = items.listenerStats()
        XCTAssertEqual(stats.processCount, 2)
        XCTAssertEqual(stats.totalRAM, 512)
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
                ramBytes: 128 * 1024 * 1024, isZombie: false, startedAt: date,
                processStartTime: date, localAddress: "127.0.0.1"
            ),
            PortItem(
                port: 5432, address: "127.0.0.1", pid: 23456, processName: "postgres",
                kind: .brew, label: "postgres", subtitle: "brew service",
                ramBytes: 64 * 1024 * 1024, isZombie: false, startedAt: date,
                processStartTime: date, localAddress: "127.0.0.1"
            ),
            PortItem(
                port: 6379, address: "127.0.0.1", pid: 34567, processName: "redis-ser",
                kind: .brew, label: "redis", subtitle: "brew service",
                ramBytes: 32 * 1024 * 1024, isZombie: false, startedAt: date,
                processStartTime: date, localAddress: "127.0.0.1"
            ),
            PortItem(
                port: 11434, address: "127.0.0.1", pid: 45678, processName: "ollama",
                kind: .ollama, label: "ollama", subtitle: "ollama",
                ramBytes: Int64(4.2 * 1024 * 1024 * 1024), isZombie: false, startedAt: date,
                processStartTime: date, localAddress: "127.0.0.1"
            ),
            PortItem(
                port: 5000, address: "0.0.0.0", pid: 56789, processName: "Python",
                kind: .other, label: "backend", subtitle: "Python",
                ramBytes: 12 * 1024 * 1024, isZombie: false, startedAt: date,
                processStartTime: date, localAddress: "0.0.0.0"
            ),
            PortItem(
                port: 8081, address: "127.0.0.1", pid: 99999, processName: "node",
                kind: .node, label: "node", subtitle: "node",
                ramBytes: 1 * 1024 * 1024, isZombie: true, startedAt: date,
                processStartTime: date, localAddress: "127.0.0.1"
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

    func testLsofExitOneWithEmptyOutputReturnsEmpty() async throws {
        // FakeProcessRunner default stderr is nil; lsof status 1 + empty stdout => no listeners.
        let runner = FakeProcessRunner(results: [
            ProcessRunResult(status: 1, output: "", stderr: nil)
        ])
        let scanner = LsofPortScanner(runner: runner, provider: StubProcessInfoProvider(referenceDate: Date()))
        let items = try await scanner.scan()
        XCTAssertTrue(items.isEmpty)
    }


    func testLsofNonZeroWithOutputParsesRows() async throws {
        let runner = FakeProcessRunner(results: [
            ProcessRunResult(status: 1, output: "COMMAND PID USER...\nnode 123 user 1u IPv4 0x0 0t0 TCP 127.0.0.1:3000 (LISTEN)")
        ])
        let scanner = LsofPortScanner(runner: runner, provider: StubProcessInfoProvider(referenceDate: Date()))
        let items = try await scanner.scan()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.port, 3000)
    }

    func testLsofNonZeroWithEmptyOutputThrows() async throws {
        let runner = FakeProcessRunner(results: [
            ProcessRunResult(status: 2, output: "", stderr: "boom")
        ])
        let scanner = LsofPortScanner(runner: runner, provider: StubProcessInfoProvider(referenceDate: Date()))
        await XCTAssertThrowsErrorAsync(try await scanner.scan())
    }

    func testLsofTimedOutThrows() async throws {
        let runner = TimingFakeProcessRunner(scans: [
            (delay: 0.05, result: .success(ProcessRunResult(status: 0, output: "", timedOut: true)))
        ])
        let scanner = LsofPortScanner(runner: runner, provider: StubProcessInfoProvider(referenceDate: Date()))
        await XCTAssertThrowsErrorAsync(try await scanner.scan())
    }

    // MARK: - Real ProcessRunner

    func testRealProcessRunnerEcho() async throws {
        let runner = RealProcessRunner()
        let result = try await runner.run(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["hi"],
            timeout: 5.0
        )
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, "hi\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertFalse(result.timedOut)
    }

    func testRealProcessRunnerTimesOut() async throws {
        let runner = RealProcessRunner()
        let result = try await runner.run(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["5"],
            timeout: 0.2
        )
        XCTAssertTrue(result.timedOut)
    }

    func testLsofWildcardDualStackCollapsesToOneRow() throws {
        let date = Date(timeIntervalSince1970: 4_000_000)
        let scanner = LsofPortScanner(provider: StubProcessInfoProvider(referenceDate: date))
        let output = try fixture(named: "lsof-wildcard-dualstack.txt")
        let items = scanner.parse(output).sortedForDisplay()

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.pid, 22222)
        XCTAssertEqual(items.first?.port, 3000)
        XCTAssertEqual(items.first?.address, "*")
    }

    func testLsofRealFixtureParsesWithoutCrashing() throws {
        let date = Date(timeIntervalSince1970: 7_000_000)
        let output = try fixture(named: "lsof-real-2026-10-25.txt")
        let scanner = LsofPortScanner(provider: StubProcessInfoProvider(referenceDate: date))
        let items = scanner.parse(output)
        XCTAssertEqual(items.count, 34)

        // No (pid, port, address) duplicates; lsof address rows are unique in the output.
        let ids = items.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)

        // Wildcard dual-stack rows collapse to a single `*` address row per (pid, port).
        let wildcardRows = items.filter { $0.address == "*" }
        for row in wildcardRows {
            let matching = items.filter { $0.pid == row.pid && $0.port == row.port }
            XCTAssertEqual(matching.count, 1, "wildcard row for pid \(row.pid) port \(row.port) should be unique")
        }

        // No .other listener should be flagged zombie just because it's launchd-parented.
        for item in items where item.isZombie {
            XCTAssertEqual(item.kind, .node, "only node listeners should be flagged zombie, got \(item.kind) for \(item.processName)")
        }
    }

    func testBrewUnderLaunchdIsNotZombie() throws {
        let date = Date(timeIntervalSince1970: 5_000_000)
        let scanner = LsofPortScanner(provider: StubProcessInfoProvider(referenceDate: date))
        let output = try fixture(named: "lsof-launchd-postgres.txt")
        let items = scanner.parse(output).sortedForDisplay()

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.kind, .brew)
        XCTAssertEqual(items.first?.isZombie, false)
    }

    func testOtherUnderLaunchdIsNotZombie() throws {
        let date = Date(timeIntervalSince1970: 6_000_000)
        let scanner = LsofPortScanner(provider: StubProcessInfoProvider(referenceDate: date))
        let output = try fixture(named: "lsof-launchd-python.txt")
        let items = scanner.parse(output).sortedForDisplay()

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.kind, .other)
        XCTAssertEqual(items.first?.isZombie, false)
    }

    func testNodeUnderLaunchdIsZombie() throws {
        let date = Date(timeIntervalSince1970: 6_100_000)
        let scanner = LsofPortScanner(provider: StubProcessInfoProvider(referenceDate: date))
        let output = try fixture(named: "lsof-launchd-node.txt")
        let items = scanner.parse(output).sortedForDisplay()

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.kind, .node)
        XCTAssertEqual(items.first?.isZombie, true)
    }

    func testIntelHomebrewPostgresqlDetectedAsBrew() throws {
        let date = Date(timeIntervalSince1970: 6_200_000)
        let scanner = LsofPortScanner(provider: StubProcessInfoProvider(referenceDate: date))
        let output = try fixture(named: "lsof-intel-postgres.txt")
        let items = scanner.parse(output).sortedForDisplay()

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.kind, .brew)
        XCTAssertEqual(items.first?.isZombie, false)
    }

    // MARK: - PortStore scan scheduling (N1)

    @MainActor
    func testScanDropTickDoesNotCancelInFlightScan() async throws {
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

        await fulfillment(of: [expectation], timeout: 1.0)
        cancellable.cancel()

        XCTAssertEqual(slow.invocations, 1)
        XCTAssertEqual(store.listeners, [item])
    }

    @MainActor
    func testScanTaskResetAllowsSecondTick() async throws {
        let item = PortItem(
            port: 4000, address: "127.0.0.1", pid: 777, processName: "node",
            kind: .node, label: "test", subtitle: "node",
            ramBytes: 1 * 1024 * 1024, isZombie: false
        )
        let fast = FakePortScanner(results: [[item], [item]])
        let store = PortStore(scanner: fast)

        store.tick()
        let first = expectation(description: "first publish")
        let cancellable = store.$listeners
            .dropFirst()
            .sink { _ in first.fulfill() }
        await fulfillment(of: [first], timeout: 1.0)
        cancellable.cancel()

        // Wait for the task to finish resetting scanTask on the main actor.
        try await Task.sleep(for: .milliseconds(50))

        store.tick()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(fast.invocations, 2)
    }

    @MainActor
    func testStaleScanTaskDoesNotClobberNewerResult() async throws {
        let item = PortItem(
            port: 4000, address: "127.0.0.1", pid: 777, processName: "node",
            kind: .node, label: "test", subtitle: "", ramBytes: 1, isZombie: false
        )
        let slow = SlowPortScanner(delay: 0.05, result: [item])
        let store = PortStore(scanner: slow)

        store.tick() // scan 1 in-flight
        try await Task.sleep(for: .milliseconds(10))
        store.tick() // must drop because scan 1 still running
        XCTAssertEqual(slow.invocations, 1)
        XCTAssertNotNil(store.scanTask)

        let expectation = expectation(description: "publish")
        let cancellable = store.$listeners
            .dropFirst()
            .sink { _ in expectation.fulfill() }
        await fulfillment(of: [expectation], timeout: 1.0)
        cancellable.cancel()

        XCTAssertEqual(store.listeners, [item])

        try await Task.sleep(for: .milliseconds(20))
        store.tick() // scan 2 should now run after scan 1 finished
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertEqual(slow.invocations, 2)
    }

    @MainActor
    func testStopScanningSuppressesPublish() async throws {
        let item = PortItem(
            port: 4000, address: "127.0.0.1", pid: 777, processName: "node",
            kind: .node, label: "test", subtitle: "node",
            ramBytes: 1 * 1024 * 1024, isZombie: false
        )
        let slow = SlowPortScanner(delay: 0.3, result: [item])
        let store = PortStore(scanner: slow)

        store.startScanning(interval: 10)
        store.stopScanning()

        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(store.listeners.isEmpty)
    }

    @MainActor
    func testProcessCountAndTotalRAMDeduped() async throws {
        let items = [
            PortItem(port: 3000, address: "127.0.0.1", pid: 100, processName: "node", kind: .node, label: "a", subtitle: "", ramBytes: 100, isZombie: false),
            PortItem(port: 3000, address: "[::1]", pid: 100, processName: "node", kind: .node, label: "a", subtitle: "", ramBytes: 100, isZombie: false),
            PortItem(port: 4000, address: "127.0.0.1", pid: 200, processName: "node", kind: .node, label: "b", subtitle: "", ramBytes: 50, isZombie: false)
        ]
        let store = PortStore(scanner: FakePortScanner(results: [items]))
        store.tick()

        let expectation = expectation(description: "publish")
        let cancellable = store.$listeners
            .dropFirst()
            .sink { _ in expectation.fulfill() }
        await fulfillment(of: [expectation], timeout: 1.0)
        cancellable.cancel()

        XCTAssertEqual(store.processCount, 2)
        XCTAssertEqual(store.totalRAM, 150)
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
        case 22222:
            return ProcessMetadata(
                executablePath: "/Users/dev/Codebases/myshop/node_modules/.bin/node",
                ramBytes: 96 * 1024 * 1024,
                parentPID: 600,
                startedAt: referenceDate
            )
        case 77777:
            return ProcessMetadata(
                executablePath: "/opt/homebrew/opt/postgresql@16/bin/postgres",
                ramBytes: 32 * 1024 * 1024,
                parentPID: 1,
                startedAt: referenceDate
            )
        case 88888:
            return ProcessMetadata(
                executablePath: "/usr/bin/python3",
                ramBytes: 8 * 1024 * 1024,
                parentPID: 1,
                startedAt: referenceDate
            )
        case 66666:
            return ProcessMetadata(
                executablePath: "/usr/local/bin/node",
                ramBytes: 16 * 1024 * 1024,
                parentPID: 1,
                startedAt: referenceDate
            )
        case 55555:
            return ProcessMetadata(
                executablePath: "/usr/local/opt/postgresql@16/bin/postgres",
                ramBytes: 32 * 1024 * 1024,
                parentPID: 1,
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

    func scan() async throws -> [PortItem] {
        lock.withLock { _invocations += 1 }
        try await Task.sleep(for: .seconds(delay))
        return result
    }
}

private final class FakePortScanner: PortScanner, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [[PortItem]]
    private var _invocations = 0

    var invocations: Int {
        lock.withLock { _invocations }
    }

    init(results: [[PortItem]]) {
        self.results = results
    }

    func scan() async throws -> [PortItem] {
        lock.withLock { _invocations += 1 }
        guard !results.isEmpty else { return [] }
        let next = results.removeFirst()
        return next
    }
}

private final class FakeProcessRunner: ProcessRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [ProcessRunResult]

    init(results: [ProcessRunResult]) {
        self.results = results
    }

    func run(executableURL: URL, arguments: [String], timeout: TimeInterval) async throws -> ProcessRunResult {
        lock.withLock {
            guard !results.isEmpty else { return ProcessRunResult(status: 0, output: "") }
            return results.removeFirst()
        }
    }
}

private final class TimingFakeProcessRunner: ProcessRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var scans: [(delay: TimeInterval, result: Result<ProcessRunResult, Error>)]
    private var _invocations = 0

    var invocations: Int {
        lock.withLock { _invocations }
    }

    init(scans: [(delay: TimeInterval, result: Result<ProcessRunResult, Error>)]) {
        self.scans = scans
    }

    func run(executableURL: URL, arguments: [String], timeout: TimeInterval) async throws -> ProcessRunResult {
        lock.withLock { _invocations += 1 }
        guard !scans.isEmpty else { return ProcessRunResult(status: 0, output: "") }
        let next = scans.removeFirst()
        try await Task.sleep(for: .seconds(next.delay))
        return try next.result.get()
    }
}

private func fixture(named name: String) throws -> String {
    let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let fixtureURL = testsDir
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/\(name)")
    return try String(contentsOf: fixtureURL, encoding: .utf8)
}

private extension XCTestCase {
    func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await expression()
            XCTFail(message(), file: file, line: line)
        } catch {
            // expected
        }
    }
}
