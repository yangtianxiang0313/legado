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

  func testAndroidTruthPreservesTOCFlagsAndEmptyURLFallback() async throws {
    let rules = TOCRules(
      list: ".chapter",
      name: HTMLCSSRule(".name"),
      url: HTMLCSSRule("a", value: .href),
      isVIP: HTMLCSSRule(".vip"),
      isPay: HTMLCSSRule(".pay"),
      isVolume: HTMLCSSRule(".volume"),
      nextTocURL: HTMLCSSRule("a.next", value: .href)
    )
    let transport = TOCTransport(responses: [
      "http://sourcelab.test/toc/one": """
        <main>
          <li class="chapter"><a href="/chapter/1"><span class="name">第一章</span></a><span class="vip">true</span></li>
          <li class="chapter"><a href="/chapter/2"><span class="name">第二章</span></a><span class="pay">true</span></li>
          <a class="next" href="/toc/two">下一页</a>
        </main>
        """,
      "http://sourcelab.test/toc/two": """
        <main>
          <li class="chapter"><a href="/chapter/2"><span class="name">第二章</span></a><span class="pay">true</span></li>
          <li class="chapter"><a href="/chapter/3"><span class="name">第三章</span></a></li>
        </main>
        """,
      "http://sourcelab.test/toc/fallback": """
        <main>
          <li class="chapter"><span class="name">第一卷</span><span class="volume">true</span></li>
          <li class="chapter"><span class="name">无链接章节</span></li>
        </main>
        """,
    ])
    let pipeline = SourceTOCPipeline(
      definition: definition(toc: rules),
      transport: transport
    )

    let paged = try await pipeline.chapters(
      tocURL: "http://sourcelab.test/toc/one"
    )
    XCTAssertEqual(
      paged.requests.map { $0.url.absoluteString },
      ["http://sourcelab.test/toc/one", "http://sourcelab.test/toc/two"]
    )
    XCTAssertEqual(paged.chapters.map(\.title), ["第一章", "第二章", "第三章"])
    XCTAssertEqual(paged.chapters.map(\.index), [0, 1, 2])
    XCTAssertEqual(paged.chapters.map(\.isVIP), [true, false, false])
    XCTAssertEqual(paged.chapters.map(\.isPay), [false, true, false])
    XCTAssertEqual(paged.chapters.map(\.isVolume), [false, false, false])

    let fallback = try await pipeline.chapters(
      tocURL: "http://sourcelab.test/toc/fallback"
    )
    XCTAssertEqual(fallback.chapters.map(\.title), ["第一卷", "无链接章节"])
    XCTAssertEqual(
      fallback.chapters.map { $0.url.absoluteString },
      ["http://sourcelab.test/toc/fallback", "http://sourcelab.test/toc/fallback"]
    )
    XCTAssertEqual(fallback.chapters.map(\.isVolume), [true, false])
    XCTAssertEqual(fallback.chapters[0].endpoint.requestExpression, "第一卷0")
  }

  private func definition(
    toc: TOCRules = TOCRules(
      list: ".chapter",
      name: HTMLCSSRule("a"),
      url: HTMLCSSRule("a", value: .href)
    )
  ) -> SourceSearchDefinition {
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
        toc: toc,
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
