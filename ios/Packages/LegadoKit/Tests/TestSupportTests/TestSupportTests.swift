import XCTest

@testable import TestSupport

final class TestSupportTests: XCTestCase {
  func testModuleIdentifier() {
    XCTAssertEqual(TestSupportModule.identifier, "TestSupport")
  }
}
