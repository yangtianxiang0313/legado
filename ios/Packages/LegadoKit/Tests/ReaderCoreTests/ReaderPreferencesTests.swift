@testable import ReaderCore
import Foundation
import XCTest

final class ReaderPreferencesTests: XCTestCase {
  func testDefaultsFollowPortableAndroidReadingValues() {
    let value = ReaderPreferences()

    XCTAssertFalse(value.darkTheme)
    XCTAssertEqual(value.brightness, 1)
    XCTAssertEqual(value.fontSize, 20)
    XCTAssertEqual(value.lineSpacing, 12)
    XCTAssertFalse(value.autoPageEnabled)
    XCTAssertEqual(value.preDownloadCount, 10)
    XCTAssertFalse(value.tocUsesReplacementRules)
    XCTAssertEqual(value.pageAnimation, 0)
  }

  func testValuesAreClampedAtDomainBoundary() {
    let value = ReaderPreferences(
      brightness: -10,
      fontSize: 200,
      lineSpacing: -1,
      preDownloadCount: 20_000
    )

    XCTAssertEqual(value.brightness, 0.4)
    XCTAssertEqual(value.fontSize, 32)
    XCTAssertEqual(value.lineSpacing, 0)
    XCTAssertEqual(value.preDownloadCount, 9_999)
  }

  func testLegacyPayloadDefaultsPreDownloadCountToAndroidValue() throws {
    let value = try JSONDecoder().decode(
      ReaderPreferences.self,
      from: Data(
        #"{"darkTheme":true,"brightness":1,"fontSize":20,"lineSpacing":12,"autoPageEnabled":false}"#.utf8
      )
    )

    XCTAssertEqual(value.preDownloadCount, 10)
    XCTAssertFalse(value.tocUsesReplacementRules)
    XCTAssertEqual(value.pageAnimation, 0)
  }
}
