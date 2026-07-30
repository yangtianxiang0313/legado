import Foundation
import LibraryDomain
import XCTest

final class LocalTextBookTests: XCTestCase {
  func testDefaultAndroidStyleHeadingsProducePrefaceAndChapters()
    throws
  {
    let text = """
      前言内容
      第一章 启程
      旅程从这里开始
      Chapter 2 Return
      故事在这里继续
      """

    let document = try LocalTextBookParser.parse(Data(text.utf8))

    XCTAssertEqual(
      document.chapters.map(\.title),
      ["前言", "第一章 启程", "Chapter 2 Return"]
    )
    XCTAssertEqual(document.chapters[1].content, "旅程从这里开始")
    XCTAssertEqual(document.chapters[2].content, "故事在这里继续")
  }

  func testTextWithoutTOCStillProducesReadableChapter() throws {
    let document = try LocalTextBookParser.parse(
      Data("只有一段正文".utf8)
    )

    XCTAssertEqual(document.chapters.count, 1)
    XCTAssertEqual(document.chapters[0].title, "前言")
    XCTAssertEqual(document.chapters[0].content, "只有一段正文")
  }

  func testEmptyDataIsRejected() {
    XCTAssertThrowsError(
      try LocalTextBookParser.parse(Data())
    ) { error in
      XCTAssertEqual(error as? LocalTextBookFailure, .emptyFile)
    }
  }
}
