import AppUseCases
import Foundation
import LibraryDomain
import SourceRuntime
import XCTest

final class ReaderContentPaginationBoundaryTests: XCTestCase {
  func testSourceLoaderStopsPaginationAtPersistedNextChapter()
    async throws
  {
    let sourceID = "source-1"
    let definition = SourceSearchDefinition(
      sourceURL: "http://sourcelab.test",
      sourceName: "分页书源",
      originOrder: 1,
      runtime: HTMLCSSSourceDefinition(
        searchURLTemplate: "http://sourcelab.test/search",
        search: SearchRules(
          list: "@Json:$[*]",
          name: HTMLCSSRule("@Json:$.name"),
          author: .optional(nil),
          intro: .optional(nil),
          kind: .optional(nil),
          lastChapter: .optional(nil),
          bookURL: HTMLCSSRule("@Json:$.url", value: .href),
          coverURL: .optional(nil, value: .src)
        ),
        bookInfo: BookInfoRules(
          name: HTMLCSSRule("@Json:$.name"),
          author: .optional(nil),
          intro: .optional(nil),
          kind: .optional(nil),
          lastChapter: .optional(nil),
          coverURL: .optional(nil, value: .src),
          tocURL: HTMLCSSRule("@Json:$.toc", value: .href)
        ),
        toc: TOCRules(
          list: "@Json:$.chapters[*]",
          name: HTMLCSSRule("@Json:$.name"),
          url: HTMLCSSRule("@Json:$.url", value: .href)
        ),
        content: ContentRules(
          content: HTMLCSSRule("@Json:$.content"),
          nextContentURL: HTMLCSSRule(
            "@Json:$.next",
            value: .href
          )
        )
      )
    )
    let transport = ReaderBoundaryTransport()
    let loader = SourceReaderContentLoader(
      sources: [
        SearchSourceDescriptor(
          id: sourceID,
          name: "分页书源",
          group: "",
          definition: definition
        )
      ],
      transport: transport
    )
    let bookID = BookID(rawValue: "book-1")
    let book = ShelfBookItem(
      id: bookID,
      candidate: ShelfBookCandidate(
        name: "星河纪事",
        author: "林舟",
        kind: "",
        lastChapter: "",
        intro: "",
        bookURL: "http://sourcelab.test/book",
        coverURL: nil,
        originName: "分页书源",
        sourceID: sourceID
      ),
      membership: .member(groupID: 0),
      order: 0,
      chapterCount: 2
    )
    let first = BookChapter(
      id: ChapterID(
        sourceID: sourceID,
        chapterURL: "http://sourcelab.test/chapter-1"
      ),
      bookID: bookID,
      sourceID: sourceID,
      index: 0,
      title: "第一章",
      url: "http://sourcelab.test/chapter-1"
    )
    let second = BookChapter(
      id: ChapterID(
        sourceID: sourceID,
        chapterURL: "http://sourcelab.test/chapter-2"
      ),
      bookID: bookID,
      sourceID: sourceID,
      index: 1,
      title: "第二章",
      url: "http://sourcelab.test/chapter-2"
    )

    let document = try await loader.load(
      book: book,
      chapter: first,
      nextChapter: second,
      characterOffset: 0
    )

    XCTAssertEqual(document.content, "第一章正文")
    let paths = await transport.paths()
    XCTAssertEqual(paths, ["/chapter-1"])
  }
}

private actor ReaderBoundaryTransport: HTTPTransport {
  private var recordedPaths: [String] = []

  func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
    let path = URL(string: request.url.absoluteString)?.path ?? ""
    recordedPaths.append(path)
    guard path == "/chapter-1" else {
      throw HTTPTransportFailure.connectionFailed
    }
    return try HTTPResponse(
      statusCode: 200,
      effectiveURL: request.url,
      body: HTTPBody(
        Data(
          #"{"content":"第一章正文","next":"/chapter-2"}"#.utf8
        )
      )
    )
  }

  func paths() -> [String] {
    recordedPaths
  }
}
