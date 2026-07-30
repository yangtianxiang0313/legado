import Foundation
import XCTest

@testable import SourceRuntime

final class SourceSearchPipelineTests: XCTestCase {
  func testListSearchCompilesPageFiltersAndDeduplicatesLikeAndroid()
    async throws
  {
    let transport = SearchTransport(
      body: """
        <html><body>
          <article class="book-item">
            <a class="book-link" href="/books/a"></a>
            <span class="book-name">甲书</span>
            <span class="book-author">作者：甲</span>
            <span class="book-word-count">120000</span>
          </article>
          <article class="book-item">
            <a class="book-link" href="/books/a"></a>
            <span class="book-name">重复</span>
          </article>
          <article class="book-item">
            <a class="book-link" href="/books/blank"></a>
          </article>
        </body></html>
        """
    )
    let execution = try await SourceSearchPipeline(
      definition: definition(),
      transport: transport
    ).search(SourceSearchInput(keyword: "星河", page: 2))

    XCTAssertEqual(
      execution.requestPlan.request.url.absoluteString,
      "http://sourcelab.test/pipeline/search/2?q=%E6%98%9F%E6%B2%B3"
    )
    XCTAssertEqual(execution.books.count, 1)
    XCTAssertEqual(execution.books[0].name, "甲书")
    XCTAssertEqual(execution.books[0].author, "甲")
    XCTAssertEqual(execution.books[0].wordCount, "12万字")
    XCTAssertEqual(
      execution.books[0].bookURL,
      "http://sourcelab.test/books/a"
    )
  }

  func testMissingBookURLFallsBackToResponseAndPreservesHTML()
    async throws
  {
    let html = """
      <html><body><article class="book-item">
        <span class="book-name">无链接</span>
      </article></body></html>
      """
    let execution = try await SourceSearchPipeline(
      definition: definition(),
      transport: SearchTransport(body: html)
    ).search(SourceSearchInput(keyword: "远方", page: 1))

    XCTAssertEqual(execution.books[0].bookURL, execution.response.url)
    XCTAssertEqual(execution.books[0].infoHTML, html)
  }

  func testResponseCheckerRunsBeforeParsing() async throws {
    let execution = try await SourceSearchPipeline(
      definition: definition(),
      transport: SearchTransport(
        body: """
          <html><body><article class="locked-item">
            <a class="book-link" href="/books/unlocked"></a>
            <span class="book-name">解锁</span>
          </article></body></html>
          """
      ),
      responseChecker: UnlockingChecker()
    ).search(SourceSearchInput(keyword: "解锁", page: 3))

    XCTAssertEqual(execution.books.map(\.name), ["解锁"])
  }

  func testDetailPatternUsesBookInfoRulesAndPreservesHTML()
    async throws
  {
    let html = """
      <html><body>
        <h1 class="book-name">直达书</h1>
        <span class="book-word-count">36000</span>
      </body></html>
      """
    let execution = try await SourceSearchPipeline(
      definition: definition(
        bookURLPattern: #".*/pipeline/search/4.*"#
      ),
      transport: SearchTransport(body: html)
    ).search(SourceSearchInput(keyword: "直达", page: 4))

    XCTAssertEqual(execution.books.count, 1)
    XCTAssertEqual(execution.books[0].name, "直达书")
    XCTAssertEqual(execution.books[0].wordCount, "3.6万字")
    XCTAssertEqual(execution.books[0].infoHTML, html)
  }

  func testBlankSearchURLFailsBeforeTransport() async {
    let transport = SearchTransport(body: "<html></html>")
    let source = definition(searchURL: "  ")
    do {
      _ = try await SourceSearchPipeline(
        definition: source,
        transport: transport
      ).search(SourceSearchInput(keyword: "无请求", page: 1))
      XCTFail("expected typed issue")
    } catch {
      XCTAssertEqual(
        error as? SourceRuntimeIssue,
        SourceRuntimeIssue(
          stage: .fieldEvaluation,
          code: .ruleFailed
        )
      )
    }
    let requestCount = await transport.requestCount()
    XCTAssertEqual(requestCount, 0)
  }

  private func definition(
    searchURL: String =
      "http://sourcelab.test/pipeline/search/{{page}}?q={{key}}",
    bookURLPattern: String? = nil
  ) -> SourceSearchDefinition {
    SourceSearchDefinition(
      sourceURL: "http://sourcelab.test",
      sourceName: "测试源",
      originOrder: 37,
      bookURLPattern: bookURLPattern,
      runtime: HTMLCSSSourceDefinition(
        searchURLTemplate: searchURL,
        search: SearchRules(
          list: ".book-item",
          name: HTMLCSSRule(".book-name"),
          author: HTMLCSSRule(".book-author"),
          intro: HTMLCSSRule(".book-intro"),
          kind: HTMLCSSRule(".book-kind"),
          wordCount: HTMLCSSRule(".book-word-count"),
          lastChapter: HTMLCSSRule(".book-last-chapter"),
          bookURL: HTMLCSSRule("a.book-link", value: .href),
          coverURL: HTMLCSSRule("img.book-cover", value: .src)
        ),
        bookInfo: BookInfoRules(
          name: HTMLCSSRule("h1.book-name"),
          author: HTMLCSSRule(".book-author"),
          intro: HTMLCSSRule(".book-intro"),
          kind: HTMLCSSRule(".book-kind"),
          wordCount: HTMLCSSRule(".book-word-count"),
          lastChapter: HTMLCSSRule(".book-last-chapter"),
          coverURL: HTMLCSSRule("img.book-cover", value: .src),
          tocURL: HTMLCSSRule("a.toc-link", value: .href)
        ),
        toc: TOCRules(
          list: ".chapter",
          name: HTMLCSSRule("a"),
          url: HTMLCSSRule("a", value: .href)
        ),
        content: ContentRules(
          content: HTMLCSSRule("#content", value: .html)
        )
      )
    )
  }
}

private actor SearchTransport: HTTPTransport {
  private let body: String
  private var requests: [HTTPRequest] = []

  init(body: String) {
    self.body = body
  }

  func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
    requests.append(request)
    return try HTTPResponse(
      statusCode: 200,
      effectiveURL: request.url,
      body: HTTPBody(Data(body.utf8))
    )
  }

  func requestCount() -> Int {
    requests.count
  }
}

private struct UnlockingChecker: SourceSearchResponseChecking {
  func check(
    _ response: SourceSearchResponse,
    source: SourceSearchDefinition,
    input: SourceSearchInput
  ) async throws -> SourceSearchResponse {
    SourceSearchResponse(
      url: response.url,
      body: response.body.replacingOccurrences(
        of: "locked-item",
        with: "book-item"
      )
    )
  }
}
