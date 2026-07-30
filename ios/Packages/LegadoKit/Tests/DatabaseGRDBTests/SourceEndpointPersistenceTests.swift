import AppUseCases
import DatabaseGRDB
import Foundation
import LibraryDomain
import XCTest

final class SourceEndpointPersistenceTests: XCTestCase {
  func testBookAndChapterRequestExpressionsSurviveReopen()
    async throws
  {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "legado-endpoint-\(UUID().uuidString).sqlite"
      ).path
    defer {
      try? FileManager.default.removeItem(atPath: path)
    }
    let logicalBookURL = "http://sourcelab.test/book"
    let bookExpression =
      #"\#(logicalBookURL),{"method":"POST","body":"book=1"}"#
    let logicalChapterURL = "http://sourcelab.test/chapter-1"
    let chapterExpression =
      #"\#(logicalChapterURL),{"method":"POST","body":"chapter=1"}"#

    let repository = try GRDBBookShelfRepository(path: path)
    let book = try await repository.add(
      ShelfBookCandidate(
        name: "星河纪事",
        author: "林舟",
        kind: "科幻",
        lastChapter: "第一章",
        intro: "",
        bookURL: logicalBookURL,
        bookRequestExpression: bookExpression,
        coverURL: nil,
        originName: "端点书源",
        sourceID: "source-1"
      ),
      groupID: 0
    )
    let chapter = BookChapter(
      id: ChapterID(
        sourceID: "source-1",
        chapterURL: logicalChapterURL
      ),
      bookID: book.id,
      sourceID: "source-1",
      index: 0,
      title: "第一章",
      url: logicalChapterURL,
      requestExpression: chapterExpression
    )
    _ = try await repository.applyTOCUpdate(
      bookID: book.id,
      update: .replaced(previousCount: 0, chapters: [chapter])
    )

    let reopened = try GRDBBookShelfRepository(path: path)
    let loadedBook = try await reopened.book(forURL: logicalBookURL)
    let loadedChapters = try await reopened.chapters(bookID: book.id)
    let restoredBook = try XCTUnwrap(loadedBook)
    let restoredChapter = try XCTUnwrap(loadedChapters.first)

    XCTAssertEqual(restoredBook.candidate.bookURL, logicalBookURL)
    XCTAssertEqual(
      restoredBook.candidate.bookRequestExpression,
      bookExpression
    )
    XCTAssertEqual(restoredChapter.url, logicalChapterURL)
    XCTAssertEqual(
      restoredChapter.requestExpression,
      chapterExpression
    )
  }
}
