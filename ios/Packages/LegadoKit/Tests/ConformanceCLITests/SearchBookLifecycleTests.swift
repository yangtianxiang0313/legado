import XCTest

@testable import TestSupport

extension LibraryDomainTests {
  func testSearchBookMergePreservesFirstRepresentative() {
    let result = SearchBookLifecycleDomainProbe.merged()

    XCTAssertEqual(
      result.bookURLs,
      [
        "book://exact/source-a",
        "book://contains/source-a",
        "book://other/source-a",
      ]
    )
    XCTAssertEqual(result.originOrders, [20, 20, 20])
    XCTAssertEqual(
      result.origins,
      [
        ["source://a", "source://b"],
        ["source://a", "source://b"],
        ["source://a", "source://b"],
      ]
    )
  }

  func testSearchBookGroupsRankByOriginCount() {
    XCTAssertEqual(
      SearchBookLifecycleDomainProbe.ranked(),
      [
        "book://exact-two",
        "book://exact-one",
        "book://contains",
        "book://other",
      ]
    )
  }

  func testPrecisionSearchDropsUnrelatedCandidates() {
    XCTAssertEqual(
      SearchBookLifecycleDomainProbe.precisionCount(),
      0
    )
  }

  func testSearchBookStoreReplacementCascadeAndTTLBoundary() {
    let result = SearchBookLifecycleDomainProbe.stored()

    XCTAssertEqual(result.writeSequences, [1, 2])
    XCTAssertEqual(result.storedName, "新名字")
    XCTAssertTrue(result.sourceCascadeWorked)
    XCTAssertEqual(
      result.remainingAfterCleanup,
      ["boundary", "fresh"]
    )
  }
}
