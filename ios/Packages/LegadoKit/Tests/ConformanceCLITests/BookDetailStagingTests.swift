import LegadoCore
import XCTest

@testable import ConformanceCLI

extension LibraryDomainTests {
  func testCandidatePersistenceCopiesProgressWithoutCreatingMembership() throws {
    let result = try projection(
      "detail_candidate_save",
      chapterCount: 0,
      extra: ["seed_existing_progress": .bool(true)]
    )

    XCTAssertEqual(result["book_persisted"], .bool(true))
    XCTAssertEqual(result["copied_progress"], .bool(true))
    XCTAssertEqual(result["order_before_previous_minimum"], .bool(true))
    XCTAssertEqual(result["in_bookshelf"], .bool(false))
  }

  func testExplicitAddPersistsChaptersAndMembershipIndependentlyOfGroupZero()
    throws
  {
    let result = try projection("detail_explicit_add", chapterCount: 2)

    XCTAssertEqual(result["chapter_count"], .number(JSONNumber(2)))
    XCTAssertEqual(result["group"], .number(JSONNumber(0)))
    XCTAssertEqual(result["in_bookshelf"], .bool(true))
  }

  func testTableOfContentsStagesWithoutMembership() throws {
    let result = try projection("detail_toc_stage", chapterCount: 2)

    XCTAssertEqual(result["book_persisted"], .bool(true))
    XCTAssertEqual(result["chapter_count"], .number(JSONNumber(2)))
    XCTAssertEqual(result["in_bookshelf"], .bool(false))
  }

  func testOnlyPositiveGroupSelectionCommitsCandidate() throws {
    let zero = try projection(
      "detail_group_selection",
      chapterCount: 0,
      extra: ["group_id": .number(JSONNumber(0))]
    )
    let positive = try projection(
      "detail_group_selection",
      chapterCount: 0,
      extra: ["group_id": .number(JSONNumber(2))]
    )

    XCTAssertEqual(zero["book_persisted"], .bool(false))
    XCTAssertEqual(positive["book_persisted"], .bool(true))
    XCTAssertEqual(positive["group"], .number(JSONNumber(2)))
    XCTAssertEqual(positive["in_bookshelf"], .bool(true))
  }

  func testReaderDiscardDeletesStagedBookAndChapters() throws {
    let result = try projection("reader_discard_staged", chapterCount: 2)

    XCTAssertEqual(result["book_persisted"], .bool(false))
    XCTAssertEqual(result["chapter_count"], .number(JSONNumber(0)))
  }

  private func projection(
    _ operation: String,
    chapterCount: Int64,
    extra: [String: JSONValue] = [:]
  ) throws -> [String: JSONValue] {
    var arguments = extra
    arguments["chapter_count"] = .number(JSONNumber(chapterCount))
    guard
      case .object(let result) =
        try BookDetailStagingConformanceRunner.execute(
          operation: operation,
          arguments: arguments
        )
    else {
      XCTFail("Expected object projection")
      return [:]
    }
    return result
  }
}
