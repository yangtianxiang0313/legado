import XCTest

@testable import SourceRuntime

final class SourceRuntimeTests: XCTestCase {
  func testModuleIdentifier() {
    XCTAssertEqual(SourceRuntimeModule.identifier, "SourceRuntime")
  }
}
