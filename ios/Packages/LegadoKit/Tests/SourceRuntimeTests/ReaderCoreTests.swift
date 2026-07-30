import TestSupport
import XCTest

final class ReaderCoreTests: XCTestCase {
  func testCanceledAndNullPayloadDoNotOpenReader() {
    XCTAssertNil(
      ReaderTOCHandoffFixture.project(
        completion: "canceled",
        producer: "chapter",
        selectedIndex: 4,
        currentIndex: 1,
        characterOffset: nil
      )
    )
    XCTAssertNil(
      ReaderTOCHandoffFixture.project(
        completion: "ok",
        producer: "null_intent",
        selectedIndex: nil,
        currentIndex: nil,
        characterOffset: nil
      )
    )
  }

  func testChapterBookmarkAndReversePreserveAndroidBoundarySemantics() {
    XCTAssertEqual(
      ReaderTOCHandoffFixture.project(
        completion: "ok",
        producer: "empty_intent",
        selectedIndex: nil,
        currentIndex: nil,
        characterOffset: nil
      ),
      ReaderTOCHandoffFixtureProjection(
        chapterIndex: 0,
        characterOffset: 0,
        chapterChanged: false
      )
    )
    XCTAssertEqual(
      ReaderTOCHandoffFixture.project(
        completion: "ok",
        producer: "chapter",
        selectedIndex: 5,
        currentIndex: 2,
        characterOffset: nil
      ),
      ReaderTOCHandoffFixtureProjection(
        chapterIndex: 5,
        characterOffset: 0,
        chapterChanged: true
      )
    )
    XCTAssertEqual(
      ReaderTOCHandoffFixture.project(
        completion: "ok",
        producer: "bookmark",
        selectedIndex: 3,
        currentIndex: nil,
        characterOffset: 128
      ),
      ReaderTOCHandoffFixtureProjection(
        chapterIndex: 3,
        characterOffset: 128,
        chapterChanged: false
      )
    )
    XCTAssertEqual(
      ReaderTOCHandoffFixture.project(
        completion: "ok",
        producer: "reverse",
        selectedIndex: nil,
        currentIndex: 6,
        characterOffset: nil
      ),
      ReaderTOCHandoffFixtureProjection(
        chapterIndex: 6,
        characterOffset: 0,
        chapterChanged: false
      )
    )
  }
}
