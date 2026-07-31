import ReaderCore
import XCTest

final class ReaderImageLayoutPolicyTests: XCTestCase {
  func testFullStyleUsesVisibleWidthWithoutHeightClamp() throws {
    let size = try XCTUnwrap(ReaderImageLayoutPolicy.size(
      naturalWidth: 100, naturalHeight: 300,
      visibleWidth: 120, visibleHeight: 80, imageStyle: "full"
    ))
    XCTAssertEqual(size.width, 120)
    XCTAssertEqual(size.height, 360)
    XCTAssertEqual(size.horizontalInset, 0)
  }

  func testDefaultStyleContainsWithinBothVisibleDimensions() throws {
    let size = try XCTUnwrap(ReaderImageLayoutPolicy.size(
      naturalWidth: 100, naturalHeight: 300,
      visibleWidth: 120, visibleHeight: 80, imageStyle: nil
    ))
    XCTAssertEqual(size.width, 80.0 / 3.0, accuracy: 0.0001)
    XCTAssertEqual(size.height, 80)
    XCTAssertEqual(size.horizontalInset, 140.0 / 3.0, accuracy: 0.0001)
  }

  func testDefaultStyleCentersUnscaledSmallImage() {
    let size = ReaderImageLayoutPolicy.size(
      naturalWidth: 60, naturalHeight: 40,
      visibleWidth: 120, visibleHeight: 80, imageStyle: ""
    )
    XCTAssertEqual(size, ReaderImageLayoutSize(width: 60, height: 40, horizontalInset: 30))
  }
}
