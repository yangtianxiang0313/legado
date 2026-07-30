import Foundation
import ScriptJavaScriptCore
import SourceRuntime
import XCTest

final class SourceJSLibraryProductIntegrationTests: XCTestCase {
  func testInlineLibraryServesLoginCheckAndSearchThroughContentRules()
    async throws
  {
    let definition = libraryDefinition()
    let runtime = JavaScriptCoreSourceScriptRuntime()
    let transport = JSLibraryTransport()

    let search = try await SourceSearchPipeline(
      definition: definition,
      transport: transport,
      scriptRuntime: runtime
    ).search(SourceSearchInput(keyword: "共享库", page: 1))
    let explore = try await SourceExplorePipeline(
      definition: SourceExploreDefinition(
        source: definition,
        enabled: true,
        catalog: ""
      ),
      transport: transport,
      scriptRuntime: runtime
    ).explore(
      SourceExploreInput(
        category: SourceExploreCategory(
          title: "共享库",
          urlTemplate: "https://jslib.example/explore"
        ),
        page: 1
      )
    )
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
      tocEndpoint: nil
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
    ).content(endpoint: chapter.endpoint)

    XCTAssertEqual("库1-搜索书", found.name)
    XCTAssertEqual("库1-发现书", explore.books.first?.name)
    XCTAssertEqual("库1-详情书", toc.book.name)
    XCTAssertEqual("库1-第一章", chapter.title)
    XCTAssertEqual("库1-正文", content.content.content)
  }

  private func libraryDefinition() -> SourceSearchDefinition {
    let listRules = SearchRules(
      list: "@Json:$[*]",
      name: HTMLCSSRule(
        "@js:decorate(JSON.parse(result).name)"
      ),
      author: HTMLCSSRule("@Json:$.author"),
      intro: .optional(nil),
      kind: .optional(nil),
      lastChapter: .optional(nil),
      bookURL: HTMLCSSRule("@Json:$.url", value: .href),
      coverURL: .optional(nil)
    )
    return SourceSearchDefinition(
      sourceURL: "https://jslib.example",
      sourceName: "共享脚本库书源",
      originOrder: 0,
      loginCheckScript: "unlock(result)",
      scriptLibrary: SourceScriptLibrary(
        source: """
          globalThis.libraryLoadCount =
            (globalThis.libraryLoadCount || 0) + 1;
          function unlock(response) {
            return new Packages.io.legado.app.help.http.StrResponse(
              response.url(),
              String(response.body()).replace("lockedName", "name")
            );
          }
          function decorate(value) {
            return "库" + libraryLoadCount + "-" + value;
          }
          """
      ),
      runtime: HTMLCSSSourceDefinition(
        searchURLTemplate: "https://jslib.example/search",
        search: listRules,
        explore: listRules,
        bookInfo: BookInfoRules(
          name: HTMLCSSRule(
            "@js:decorate(JSON.parse(result).name)"
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
            "@js:decorate(JSON.parse(result).name)"
          ),
          url: HTMLCSSRule("@Json:$.url", value: .href)
        ),
        content: ContentRules(
          content: HTMLCSSRule(
            "@js:decorate(JSON.parse(result).name)"
          )
        )
      )
    )
  }
}

private actor JSLibraryTransport: HTTPTransport {
  func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
    let body: String
    switch URL(string: request.url.absoluteString)?.path {
    case "/search":
      body =
        #"[{"lockedName":"搜索书","author":"作者","url":"/book"}]"#
    case "/explore":
      body =
        #"[{"lockedName":"发现书","author":"作者","url":"/book"}]"#
    case "/book":
      body =
        #"{"lockedName":"详情书","author":"作者","toc":"/toc"}"#
    case "/toc":
      body =
        #"{"chapters":[{"lockedName":"第一章","url":"/content"}]}"#
    case "/content":
      body = #"{"lockedName":"正文"}"#
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
