import Foundation
import XCTest

@testable import SourceRuntime

final class SourceTOCPipelineTests: XCTestCase {
  func testBookDetailAndTOCResponsesProduceStructuredChapters() async throws {
    let transport = TOCTransport(responses: [
      "http://sourcelab.test/books/star-river": """
        <html><body>
          <h1 class="book-name">星河纪事</h1>
          <a class="toc-link" href="/books/star-river/chapters">目录</a>
        </body></html>
        """,
      "http://sourcelab.test/books/star-river/chapters": """
        <html><body>
          <li class="chapter"><a href="/chapters/1">第一章 启程</a></li>
          <li class="chapter"><a href="/chapters/2">第二章 回声</a></li>
          <li class="chapter"><a href="/chapters/3">第三章 星门</a></li>
        </body></html>
        """,
    ])

    let result = try await SourceTOCPipeline(
      definition: definition(),
      transport: transport
    ).chapters(bookURL: "http://sourcelab.test/books/star-river")

    XCTAssertEqual(result.requests.count, 2)
    XCTAssertEqual(
      result.chapters.map(\.title),
      ["第一章 启程", "第二章 回声", "第三章 星门"]
    )
    XCTAssertEqual(
      result.chapters.map(\.url.absoluteString),
      [
        "http://sourcelab.test/chapters/1",
        "http://sourcelab.test/chapters/2",
        "http://sourcelab.test/chapters/3",
      ]
    )
  }

  private func definition() -> SourceSearchDefinition {
    SourceSearchDefinition(
      sourceURL: "http://sourcelab.test",
      sourceName: "测试源",
      originOrder: 0,
      runtime: HTMLCSSSourceDefinition(
        searchURLTemplate: "http://sourcelab.test/search?q={{key}}",
        search: SearchRules(
          list: ".book",
          name: HTMLCSSRule(".name"),
          author: HTMLCSSRule(".author"),
          intro: HTMLCSSRule(".intro"),
          kind: HTMLCSSRule(".kind"),
          lastChapter: HTMLCSSRule(".last"),
          bookURL: HTMLCSSRule("a", value: .href),
          coverURL: HTMLCSSRule("img", value: .src)
        ),
        bookInfo: BookInfoRules(
          name: HTMLCSSRule(".book-name"),
          author: HTMLCSSRule(".book-author"),
          intro: HTMLCSSRule(".book-intro"),
          kind: HTMLCSSRule(".book-kind"),
          lastChapter: HTMLCSSRule(".book-last"),
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

private actor TOCTransport: HTTPTransport {
  let responses: [String: String]

  init(responses: [String: String]) {
    self.responses = responses
  }

  func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
    guard let body = responses[request.url.absoluteString] else {
      throw URLError(.resourceUnavailable)
    }
    return try HTTPResponse(
      statusCode: 200,
      effectiveURL: request.url,
      body: HTTPBody(Data(body.utf8))
    )
  }
}
