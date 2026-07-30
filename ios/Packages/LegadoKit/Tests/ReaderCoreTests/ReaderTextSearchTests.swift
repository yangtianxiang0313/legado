import LibraryDomain
@testable import ReaderCore
import XCTest

final class ReaderTextSearchTests: XCTestCase {
  func testSearchReturnsEveryNonOverlappingUTF16PositionAndContext() {
    let bookID = BookID(rawValue: "book")
    let chapterID = ChapterID(rawValue: "chapter")
    let content = "前缀🚀目标，中段目标，结尾"

    let results = ReaderTextSearch.results(
      content: content,
      query: "目标",
      bookID: bookID,
      chapterID: chapterID,
      chapterIndex: 3,
      chapterTitle: "第四章",
      contextLength: 3
    )

    XCTAssertEqual(results.count, 2)
    XCTAssertEqual(
      results.map(\.characterOffset),
      [
        (content as NSString).range(of: "目标").location,
        (content as NSString).range(
          of: "目标",
          options: [],
          range: NSRange(
            location: 7,
            length: (content as NSString).length - 7
          )
        ).location,
      ]
    )
    XCTAssertTrue(results.allSatisfy { $0.excerpt.contains("目标") })
    XCTAssertEqual(results.map(\.chapterIndex), [3, 3])
  }

  func testEmptyQueryDoesNotLoopOrMatch() {
    XCTAssertEqual(
      ReaderTextSearch.results(
        content: "正文",
        query: "",
        bookID: BookID(rawValue: "book"),
        chapterID: ChapterID(rawValue: "chapter"),
        chapterIndex: 0,
        chapterTitle: "第一章"
      ),
      []
    )
  }
}
