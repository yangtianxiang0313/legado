import Foundation
import ScriptJavaScriptCore
import SourceRuntime
import XCTest

final class SourceLoginCheckProductIntegrationTests: XCTestCase {
  func testLoginCheckTransformsAllFiveSourcePipelineStages()
    async throws
  {
    let definition = loginCheckDefinition()
    let runtime = JavaScriptCoreSourceScriptRuntime()
    let transport = LoginCheckTransport()

    let search = try await SourceSearchPipeline(
      definition: definition,
      transport: transport,
      scriptRuntime: runtime
    ).search(SourceSearchInput(keyword: "登录", page: 1))
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
          title: "登录分类",
          urlTemplate: "https://login.example/explore"
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

    XCTAssertEqual("搜索解锁书", found.name)
    XCTAssertEqual("发现解锁书", explore.books.first?.name)
    XCTAssertEqual("详情解锁书", toc.book.name)
    XCTAssertEqual("第一章", chapter.title)
    XCTAssertEqual("　　登录后正文", content.content.content)
  }

  func testReplacementURLBecomesRelativeBookLinkBase() async throws {
    let base = loginCheckDefinition(
      loginCheckScript: """
        new Packages.io.legado.app.help.http.StrResponse(
          "https://cdn.example/unlocked/index.html",
          String(result.body()).replace("locked-item", "book-item")
        )
        """
    )

    let result = try await SourceSearchPipeline(
      definition: base,
      transport: LoginCheckTransport(),
      scriptRuntime: JavaScriptCoreSourceScriptRuntime()
    ).search(SourceSearchInput(keyword: "登录", page: 1))

    XCTAssertEqual(
      "https://cdn.example/books/detail",
      result.books.first?.bookURL
    )
    XCTAssertEqual(
      "https://cdn.example/unlocked/index.html",
      result.response.url
    )
  }

  private func loginCheckDefinition(
    loginCheckScript: String = """
      new Packages.io.legado.app.help.http.StrResponse(
        result.url(),
        String(result.body()).replace("locked-item", "book-item")
      )
      """
  ) -> SourceSearchDefinition {
    let listRules = SearchRules(
      list: ".book-item",
      name: HTMLCSSRule(".book-name"),
      author: HTMLCSSRule(".book-author"),
      intro: .optional(nil),
      kind: .optional(nil),
      lastChapter: .optional(nil),
      bookURL: HTMLCSSRule(".book-name", value: .href),
      coverURL: .optional(nil)
    )
    return SourceSearchDefinition(
      sourceURL: "https://login.example",
      sourceName: "登录校验书源",
      originOrder: 0,
      loginCheckScript: loginCheckScript,
      runtime: HTMLCSSSourceDefinition(
        searchURLTemplate: "https://login.example/search",
        search: listRules,
        explore: listRules,
        bookInfo: BookInfoRules(
          name: HTMLCSSRule(".book-item .detail-name"),
          author: HTMLCSSRule(".book-item .detail-author"),
          intro: .optional(nil),
          kind: .optional(nil),
          lastChapter: .optional(nil),
          coverURL: .optional(nil),
          tocURL: HTMLCSSRule(
            ".book-item .toc-link",
            value: .href
          ),
          allowsRename: true
        ),
        toc: TOCRules(
          list: ".book-item .chapter",
          name: HTMLCSSRule("a"),
          url: HTMLCSSRule("a", value: .href)
        ),
        content: ContentRules(
          content: HTMLCSSRule(".book-item .content")
        )
      )
    )
  }
}

private actor LoginCheckTransport: HTTPTransport {
  func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
    let body: String
    switch URL(string: request.url.absoluteString)?.path {
    case "/search":
      body = """
        <div class="locked-item">
          <a class="book-name" href="../books/detail">搜索解锁书</a>
          <span class="book-author">搜索作者</span>
        </div>
        """
    case "/explore":
      body = """
        <div class="locked-item">
          <a class="book-name" href="/book">发现解锁书</a>
          <span class="book-author">发现作者</span>
        </div>
        """
    case "/books/detail", "/book":
      body = """
        <main class="locked-item">
          <h1 class="detail-name">详情解锁书</h1>
          <span class="detail-author">详情作者</span>
          <a class="toc-link" href="/toc">目录</a>
        </main>
        """
    case "/toc":
      body = """
        <ul class="locked-item">
          <li class="chapter"><a href="/content">第一章</a></li>
        </ul>
        """
    case "/content":
      body = """
        <article class="locked-item">
          <div class="content"><p>登录后正文</p></div>
        </article>
        """
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
