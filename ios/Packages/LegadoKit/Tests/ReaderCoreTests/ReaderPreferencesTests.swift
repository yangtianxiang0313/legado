@testable import ReaderCore
import XCTest

final class ReaderPreferencesTests: XCTestCase {
  func testDefaultsFollowPortableAndroidReadingValues() {
    let value = ReaderPreferences()

    XCTAssertFalse(value.darkTheme)
    XCTAssertEqual(value.brightness, 1)
    XCTAssertEqual(value.fontSize, 20)
    XCTAssertEqual(value.lineSpacing, 12)
    XCTAssertFalse(value.autoPageEnabled)
  }

  func testValuesAreClampedAtDomainBoundary() {
    let value = ReaderPreferences(
      brightness: -10,
      fontSize: 200,
      lineSpacing: -1
    )

    XCTAssertEqual(value.brightness, 0.4)
    XCTAssertEqual(value.fontSize, 32)
    XCTAssertEqual(value.lineSpacing, 0)
  }
}
