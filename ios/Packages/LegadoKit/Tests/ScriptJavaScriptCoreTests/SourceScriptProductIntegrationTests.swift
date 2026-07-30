import Foundation
import ScriptJavaScriptCore
import SourceRuntime
import XCTest

final class SourceScriptProductIntegrationTests: XCTestCase {
  func testRealJavaScriptCoreRunsSearchThroughContentPipeline()
    async throws
  {
    let definition = javaScriptDefinition()
    let runtime = JavaScriptCoreSourceScriptRuntime()
    let transport = JavaScriptProductTransport()

    let search = try await SourceSearchPipeline(
      definition: definition,
      transport: transport,
      scriptRuntime: runtime
    ).search(SourceSearchInput(keyword: "真实脚本", page: 1))
    let found = try XCTUnwrap(search.books.first)
    let book = SourceBook(
      name: found.name,
      author: found.author,
      intro: found.intro,
      kind: found.kind,
      lastChapter: found.lastChapter,
      bookEndpoint: try SourceEndpoint(
        resolving: found.bookRequestExpression,
        relativeTo: try XCTUnwrap(URL(string: definition.sourceURL))
      ),
      coverURL: nil,
      tocEndpoint: nil,
      variables: found.variables
    )

    let toc = try await SourceTOCPipeline(
      definition: definition,
      transport: transport,
      scriptRuntime: runtime
    ).chapters(book: book)
    let chapter = try XCTUnwrap(toc.chapters.first)
    let content = try await SourceContentPipeline(
      definition: definition,
      transport: transport,
      scriptRuntime: runtime
    ).content(
      endpoint: chapter.endpoint,
      bookVariables: toc.book.variables,
      chapterVariables: chapter.variables
    )

    XCTAssertEqual(found.name, "搜索原名-JS")
    XCTAssertEqual(toc.book.name, "详情原名-JS")
    XCTAssertEqual(chapter.title, "第一章-JS")
    XCTAssertEqual(content.content.content, "真实正文-JS")
  }

  private func javaScriptDefinition() -> SourceSearchDefinition {
    SourceSearchDefinition(
      sourceURL: "http://javascript.test",
      sourceName: "真实脚本书源",
      originOrder: 0,
      runtime: HTMLCSSSourceDefinition(
        searchURLTemplate: "http://javascript.test/search",
        search: SearchRules(
          list: "@Json:$[*]",
          name: HTMLCSSRule(
            "@js:JSON.parse(result).name + '-JS'"
          ),
          author: HTMLCSSRule("@Json:$.author"),
          intro: .optional(nil),
          kind: .optional(nil),
          lastChapter: .optional(nil),
          bookURL: HTMLCSSRule("@Json:$.url", value: .href),
          coverURL: .optional(nil)
        ),
        bookInfo: BookInfoRules(
          name: HTMLCSSRule(
            "@js:JSON.parse(result).name + '-JS'"
          ),
          author: HTMLCSSRule("@Json:$.author"),
          intro: .optional(nil),
          kind: .optional(nil),
          lastChapter: .optional(nil),
          coverURL: .optional(nil),
          tocURL: HTMLCSSRule("@Json:$.toc", value: .href),
          allowsRename: true
        ),
        toc: TOCRules(
          list: "@Json:$.chapters[*]",
          name: HTMLCSSRule(
            "@js:JSON.parse(result).name + '-JS'"
          ),
          url: HTMLCSSRule("@Json:$.url", value: .href)
        ),
        content: ContentRules(
          content: HTMLCSSRule(
            "@js:JSON.parse(result).content + '-JS'"
          )
        )
      )
    )
  }
}

private actor JavaScriptProductTransport: HTTPTransport {
  func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
    let body: String
    switch URL(string: request.url.absoluteString)?.path {
    case "/search":
      body =
        #"[{"name":"搜索原名","author":"脚本作者","url":"/book"}]"#
    case "/book":
      body =
        #"{"name":"详情原名","author":"脚本作者","toc":"/toc"}"#
    case "/toc":
      body =
        #"{"chapters":[{"name":"第一章","url":"/content"}]}"#
    case "/content":
      body = #"{"content":"真实正文"}"#
    default:
      throw HTTPTransportFailure.connectionFailed
    }
    return try HTTPResponse(
      statusCode: 200,
      effectiveURL: request.url,
      body: HTTPBody(Data(body.utf8))
    )
  }
}
