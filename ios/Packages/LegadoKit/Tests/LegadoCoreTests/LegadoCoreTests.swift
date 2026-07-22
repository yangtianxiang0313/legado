import XCTest

@testable import LegadoCore

final class LegadoCoreTests: XCTestCase {
  func testModuleIdentifier() {
    XCTAssertEqual(LegadoCoreModule.identifier, "LegadoCore")
  }
}
