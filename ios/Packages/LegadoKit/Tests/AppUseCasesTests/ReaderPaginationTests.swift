import LibraryDomain
@testable import AppUseCases
import ReaderCore
import XCTest

@MainActor
final class ReaderPaginationTests: XCTestCase {
  func testLayoutSelectsAnchorAndReflowsBySameCharacterPosition() {
    let paginator = FakeReaderPaginator(
      pages: [
        ReaderLayoutPage(startCharacterOffset: 0, characterCount: 5),
        ReaderLayoutPage(startCharacterOffset: 5, characterCount: 5),
        ReaderLayoutPage(startCharacterOffset: 10, characterCount: 5),
      ]
    )
    let session = ReaderPaginationSession(paginator: paginator)
    let document = makeDocument(offset: 7)

    session.layout(
      document: document,
      viewport: ReaderViewport(width: 300, height: 500),
      typography: ReaderTypography(fontSize: 20, lineSpacing: 12)
    )

    XCTAssertEqual(session.currentPageIndex, 1)
    XCTAssertEqual(session.currentCharacterOffset, 7)
    XCTAssertEqual(session.currentPageText, "56789")

    paginator.pages = [
      ReaderLayoutPage(startCharacterOffset: 0, characterCount: 3),
      ReaderLayoutPage(startCharacterOffset: 3, characterCount: 3),
      ReaderLayoutPage(startCharacterOffset: 6, characterCount: 3),
      ReaderLayoutPage(startCharacterOffset: 9, characterCount: 6),
    ]
    session.layout(
      document: document,
      viewport: ReaderViewport(width: 240, height: 400),
      typography: ReaderTypography(fontSize: 24, lineSpacing: 12)
    )

    XCTAssertEqual(session.currentPageIndex, 2)
    XCTAssertEqual(session.currentCharacterOffset, 7)
  }

  func testMovePageReturnsPersistentCharacterAnchor() {
    let paginator = FakeReaderPaginator(
      pages: [
        ReaderLayoutPage(startCharacterOffset: 0, characterCount: 5),
        ReaderLayoutPage(startCharacterOffset: 5, characterCount: 5),
      ]
    )
    let session = ReaderPaginationSession(paginator: paginator)
    session.layout(
      document: makeDocument(offset: 0),
      viewport: ReaderViewport(width: 300, height: 500),
      typography: ReaderTypography(fontSize: 20, lineSpacing: 12)
    )

    XCTAssertEqual(session.movePage(by: 1), 5)
    XCTAssertNil(session.movePage(by: 1))
    XCTAssertEqual(session.movePage(by: -1), 0)
  }

  func testChangingChapterResetsAnchorEvenWhenContentMatches() {
    let paginator = FakeReaderPaginator(
      pages: [
        ReaderLayoutPage(startCharacterOffset: 0, characterCount: 5),
        ReaderLayoutPage(startCharacterOffset: 5, characterCount: 5),
        ReaderLayoutPage(startCharacterOffset: 10, characterCount: 5),
      ]
    )
    let session = ReaderPaginationSession(paginator: paginator)
    session.layout(
      document: makeDocument(offset: 7),
      viewport: ReaderViewport(width: 300, height: 500),
      typography: ReaderTypography(fontSize: 20, lineSpacing: 12)
    )

    session.layout(
      document: makeDocument(offset: 0, chapterID: "next"),
      viewport: ReaderViewport(width: 300, height: 500),
      typography: ReaderTypography(fontSize: 20, lineSpacing: 12)
    )

    XCTAssertEqual(session.currentPageIndex, 0)
    XCTAssertEqual(session.currentCharacterOffset, 0)
  }

  func testInlineImagePageAnchorPersistsAsSourceOffset() {
    let paginator = FakeReaderPaginator(
      pages: [
        ReaderLayoutPage(startCharacterOffset: 0, characterCount: 3),
        ReaderLayoutPage(startCharacterOffset: 3, characterCount: 2),
      ]
    )
    let session = ReaderPaginationSession(paginator: paginator)
    let content = "前文<img src=\"https://example.test/image.png\">后文"
    let document = ReaderDocument(
      position: ReaderPosition(
        bookID: BookID(rawValue: "book"),
        chapterID: ChapterID(rawValue: "chapter"),
        chapterIndex: 0,
        characterOffset: 0
      ),
      title: "图文",
      content: content
    )

    session.layout(
      document: document,
      viewport: ReaderViewport(width: 300, height: 500),
      typography: ReaderTypography(fontSize: 20, lineSpacing: 12)
    )

    XCTAssertEqual(session.currentPageText, "前文\u{FFFC}")
    XCTAssertEqual(session.movePage(by: 1), (content as NSString).length - 2)
  }

  private func makeDocument(
    offset: Int,
    chapterID: String = "chapter"
  ) -> ReaderDocument {
    ReaderDocument(
      position: ReaderPosition(
        bookID: BookID(rawValue: "book"),
        chapterID: ChapterID(rawValue: chapterID),
        chapterIndex: 0,
        characterOffset: offset
      ),
      title: "第一章",
      content: "0123456789abcde"
    )
  }
}

@MainActor
private final class FakeReaderPaginator: ReaderPaginating {
  var pages: [ReaderLayoutPage]

  init(pages: [ReaderLayoutPage]) {
    self.pages = pages
  }

  func pages(
    content: String,
    viewport: ReaderViewport,
    typography: ReaderTypography
  ) -> [ReaderLayoutPage] {
    pages
  }
}
