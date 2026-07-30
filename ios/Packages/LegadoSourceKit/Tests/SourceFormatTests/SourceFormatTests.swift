import XCTest

@testable import SourceFormat

final class SourceFormatTests: XCTestCase {
  func testModuleIdentifier() {
    XCTAssertEqual(SourceFormatModule.identifier, "SourceFormat")
  }
}
