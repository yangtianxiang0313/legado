import AppUseCases
import DatabaseGRDB
import Foundation
import LibraryDomain
import ReaderCore
import XCTest

final class SourceVariablePersistenceTests: XCTestCase {
  func testBookAndChapterVariablesSurviveRepositoryReopen()
    async throws
  {
    let fixture = try await makeFixture()
    defer { try? FileManager.default.removeItem(atPath: fixture.path) }

    try await fixture.repository.saveSourceVariables(
      bookID: fixture.book.id,
      bookVariables: ["detailToken": "after-toc"],
      chapterID: fixture.chapter.id,
      chapterVariables: ["chapterToken": "after-content"]
    )

    let reopened = try GRDBBookShelfRepository(path: fixture.path)
    let loadedBook = try await reopened.book(id: fixture.book.id)
    let loadedChapters = try await reopened.chapters(
      bookID: fixture.book.id
    )
    let restoredBook = try XCTUnwrap(loadedBook)
    let restoredChapter = try XCTUnwrap(loadedChapters.first)

    XCTAssertEqual(
      restoredBook.candidate.variables,
      ["detailToken": "after-toc"]
    )
    XCTAssertEqual(
      restoredChapter.variables,
      ["chapterToken": "after-content"]
    )
  }

  func testReaderPersistsVariablesReportedBySourceRuntime()
    async throws
  {
    let fixture = try await makeFixture()
    defer { try? FileManager.default.removeItem(atPath: fixture.path) }
    let loader = RepositoryReaderContentLoader(
      repository: fixture.repository,
      fallback: ReportingReaderLoader()
    )

    let document = try await loader.load(
      book: fixture.book,
      chapter: fixture.chapter,
      characterOffset: 0
    )

    XCTAssertEqual(document.content, "正文")
    let reopened = try GRDBBookShelfRepository(path: fixture.path)
    let loadedChapters = try await reopened.chapters(
      bookID: fixture.book.id
    )
    let restoredChapter = try XCTUnwrap(loadedChapters.first)
    XCTAssertEqual(
      restoredChapter.variables,
      ["chapterToken": "written-by-content"]
    )
  }

  private func makeFixture() async throws -> (
    path: String,
    repository: GRDBBookShelfRepository,
    book: ShelfBookItem,
    chapter: BookChapter
  ) {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "legado-variables-\(UUID().uuidString).sqlite"
      ).path
    let repository = try GRDBBookShelfRepository(path: path)
    let book = try await repository.add(
      ShelfBookCandidate(
        name: "变量之书",
        author: "作者",
        kind: "",
        lastChapter: "第一章",
        intro: "",
        bookURL: "http://source.test/book",
        coverURL: nil,
        originName: "变量书源",
        sourceID: "source-1",
        variables: ["searchToken": "from-search"]
      ),
      groupID: 0
    )
    let chapter = BookChapter(
      id: ChapterID(
        sourceID: "source-1",
        chapterURL: "http://source.test/chapter-1"
      ),
      bookID: book.id,
      sourceID: "source-1",
      index: 0,
      title: "第一章",
      url: "http://source.test/chapter-1",
      variables: ["chapterToken": "from-toc"]
    )
    _ = try await repository.applyTOCUpdate(
      bookID: book.id,
      update: .replaced(previousCount: 0, chapters: [chapter]),
      bookVariables: ["detailToken": "from-toc"]
    )
    return (path, repository, book, chapter)
  }
}

private struct ReportingReaderLoader:
  SourceVariableReaderContentLoading, Sendable
{
  func load(
    book: ShelfBookItem,
    chapter: BookChapter,
    characterOffset: Int
  ) async throws -> ReaderDocument {
    try await loadSourceContent(
      book: book,
      chapter: chapter,
      nextChapter: nil,
      characterOffset: characterOffset
    ).document
  }

  func load(
    book: ShelfBookItem,
    chapter: BookChapter,
    nextChapter: BookChapter?,
    characterOffset: Int
  ) async throws -> ReaderDocument {
    try await loadSourceContent(
      book: book,
      chapter: chapter,
      nextChapter: nextChapter,
      characterOffset: characterOffset
    ).document
  }

  func loadSourceContent(
    book: ShelfBookItem,
    chapter: BookChapter,
    nextChapter: BookChapter?,
    characterOffset: Int
  ) async throws -> SourceReaderContentResult {
    let document = ReaderDocument(
      position: ReaderPosition(
        bookID: book.id,
        chapterID: chapter.id,
        chapterIndex: chapter.index,
        characterOffset: characterOffset
      ),
      title: chapter.title,
      content: "正文"
    )
    return SourceReaderContentResult(
      document: document,
      chapterVariables: ["chapterToken": "written-by-content"]
    )
  }
}
