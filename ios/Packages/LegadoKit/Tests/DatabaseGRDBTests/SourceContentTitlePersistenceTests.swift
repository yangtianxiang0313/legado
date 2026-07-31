import AppUseCases
import DatabaseGRDB
import Foundation
import LibraryDomain
import SourceRuntime
import XCTest

final class SourceContentTitlePersistenceTests: XCTestCase {
  func testSourceContentTitleUpdatesReaderAndSurvivesReopen() async throws {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("legado-content-title-\(UUID().uuidString).sqlite")
      .path
    defer { try? FileManager.default.removeItem(atPath: path) }

    let repository = try GRDBBookShelfRepository(path: path)
    let book = try await repository.add(
      ShelfBookCandidate(
        name: "标题之书", author: "作者", kind: "", lastChapter: "",
        intro: "", bookURL: "http://sourcelab.test/book", coverURL: nil,
        originName: "标题源", sourceID: "title-source"
      ),
      groupID: 0
    )
    let chapter = BookChapter(
      id: ChapterID(sourceID: "title-source", chapterURL: "http://sourcelab.test/chapter"),
      bookID: book.id, sourceID: "title-source", index: 0,
      title: "目录标题", url: "http://sourcelab.test/chapter"
    )
    _ = try await repository.applyTOCUpdate(
      bookID: book.id,
      update: .replaced(previousCount: 0, chapters: [chapter]),
      bookVariables: nil,
      tocURL: nil
    )

    let loader = RepositoryReaderContentLoader(
      repository: repository,
      fallback: SourceReaderContentLoader(
        sources: [SearchSourceDescriptor(
          id: "title-source", name: "标题源", group: "",
          definition: sourceDefinition()
        )],
        transport: TitleTransport()
      )
    )
    let document = try await loader.load(
      book: book, chapter: chapter, characterOffset: 0
    )

    XCTAssertEqual(document.title, "正文标题")
    let reopened = try GRDBBookShelfRepository(path: path)
    let chapters = try await reopened.chapters(bookID: book.id)
    let saved = try XCTUnwrap(chapters.first)
    XCTAssertEqual(saved.title, "正文标题")
  }
}

private actor TitleTransport: HTTPTransport {
  func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
    return try HTTPResponse(
      statusCode: 200,
      effectiveURL: request.url,
      body: HTTPBody(Data("<main><h1>正文标题</h1><div id=\"content\">正文</div></main>".utf8))
    )
  }
}

private func sourceDefinition() -> SourceSearchDefinition {
  SourceSearchDefinition(
    sourceURL: "http://sourcelab.test",
    sourceName: "标题源",
    originOrder: 0,
    runtime: HTMLCSSSourceDefinition(
      searchURLTemplate: "http://sourcelab.test/search",
      search: SearchRules(
        list: ".book", name: .optional(nil), author: .optional(nil),
        intro: .optional(nil), kind: .optional(nil), lastChapter: .optional(nil),
        bookURL: .optional(nil, value: .href), coverURL: .optional(nil, value: .src)
      ),
      bookInfo: BookInfoRules(
        name: .optional(nil), author: .optional(nil), intro: .optional(nil),
        kind: .optional(nil), lastChapter: .optional(nil),
        coverURL: .optional(nil, value: .src), tocURL: .optional(nil, value: .href)
      ),
      toc: TOCRules(list: ".chapter", name: .optional(nil), url: .optional(nil, value: .href)),
      content: ContentRules(
        title: HTMLCSSRule("h1"),
        content: HTMLCSSRule("#content", value: .html)
      )
    )
  )
}
