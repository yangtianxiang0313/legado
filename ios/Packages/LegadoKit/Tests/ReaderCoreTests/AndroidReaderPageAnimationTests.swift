@testable import ReaderCore
import XCTest

final class AndroidReaderPageAnimationTests: XCTestCase {
  func testBookOverrideWinsGlobalValue() {
    XCTAssertEqual(
      AndroidReaderPageAnimation.resolve(
        bookValue: 2,
        globalValue: 1,
        isImageBook: false
      ),
      .simulation
    )
  }

  func testNegativeBookValueInheritsGlobalValue() {
    XCTAssertEqual(
      AndroidReaderPageAnimation.resolve(
        bookValue: -1,
        globalValue: 1,
        isImageBook: true
      ),
      .slide
    )
  }

  func testMissingValueUsesScrollForImageBook() {
    XCTAssertEqual(
      AndroidReaderPageAnimation.resolve(
        bookValue: nil,
        globalValue: 0,
        isImageBook: true
      ),
      .scroll
    )
  }

  func testUnknownNonnegativeValueUsesAndroidNoAnimationFallback() {
    XCTAssertEqual(
      AndroidReaderPageAnimation.resolve(
        bookValue: 99,
        globalValue: 0,
        isImageBook: false
      ),
      .none
    )
  }
}
