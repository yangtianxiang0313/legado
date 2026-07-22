import XCTest

@testable import TestSupport

final class ConformanceCLITests: XCTestCase {
  func testHarnessDependencyIsAvailable() {
    XCTAssertEqual(TestSupportModule.identifier, "TestSupport")
  }
}
