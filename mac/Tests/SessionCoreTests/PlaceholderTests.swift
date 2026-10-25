import XCTest
@testable import SessionCore

final class PlaceholderTests: XCTestCase {
    func testName() { XCTAssertEqual(SessionCoreInfo.name, "SessionCore") }
}
