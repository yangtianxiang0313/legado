@testable import AppUseCases
import XCTest

final class ReaderChapterPrefetchPlanTests: XCTestCase {
  func testMatchesAndroidForwardAndBackwardWindows() {
    let plan = ReaderChapterPrefetchPlan(
      currentChapterIndex: 10,
      chapterCount: 30,
      preDownloadCount: 10
    )

    XCTAssertEqual(plan.forward, Array(12...20))
    XCTAssertEqual(plan.backward, [8, 7, 6, 5])
  }

  func testClampsAtBookBoundaries() {
    let plan = ReaderChapterPrefetchPlan(
      currentChapterIndex: 1,
      chapterCount: 5,
      preDownloadCount: 10
    )

    XCTAssertEqual(plan.forward, [3, 4])
    XCTAssertEqual(plan.backward, [])
  }

  func testCountBelowTwoDisablesPrefetch() {
    XCTAssertTrue(
      ReaderChapterPrefetchPlan(
        currentChapterIndex: 10,
        chapterCount: 30,
        preDownloadCount: 1
      ).isEmpty
    )
  }
}
