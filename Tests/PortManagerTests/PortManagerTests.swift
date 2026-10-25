import Core
import XCTest
@testable import Core

final class PortManagerTests: XCTestCase {
    func testMockPortScannerReturnsSixFixtures() throws {
        let scanner = MockPortScanner()
        let items = try scanner.scan()
        XCTAssertEqual(items.count, 6)
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
}
