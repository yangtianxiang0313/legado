import Foundation
import XCTest

@testable import SourceRuntime

final class SourceBookInfoPipelineTests: XCTestCase {
  func testFetchAndPrefetchedHTMLFollowAndroidBookInfoSemantics()
    async throws
  {
    let source = definition()
    let originalURL = URL(
      string: "http://sourcelab.test/books/star-river/index.html"
    )!
    let existing = SourceBook(
      name: "搜索阶段书名",
      author: "搜索作者",
      intro: "旧简介",
      kind: nil,
      wordCount: nil,
      lastChapter: nil,
      bookURL: originalURL,
      coverURL: nil,
      tocURL: nil
    )
    let fetched = try await SourceBookInfoPipeline(
      definition: source,
      transport: BookInfoTransport(
        effectiveURL: URL(
          string: "http://cdn.sourcelab.test/redirect/detail.html"
        )!,
        body: detailHTML
      )
    ).load(book: existing)

    XCTAssertNotNil(fetched.requestPlan)
    XCTAssertEqual(fetched.book.name, "搜索阶段书名")
    XCTAssertEqual(fetched.book.author, "搜索作者")
    XCTAssertEqual(fetched.book.intro, "新简介")
    XCTAssertEqual(fetched.book.kind, "科幻,冒险")
    XCTAssertEqual(fetched.book.wordCount, "12万字")
    XCTAssertEqual(
      fetched.book.coverURL?.absoluteString,
      "http://cdn.sourcelab.test/redirect/cover.svg"
    )
    XCTAssertEqual(
      fetched.book.tocURL?.absoluteString,
      "http://sourcelab.test/books/star-river/toc.html"
    )

    let prefetched = try await SourceBookInfoPipeline(
      definition: source,
      transport: FailingBookInfoTransport()
    ).load(
      book: SourceBook(
        name: "",
        author: nil,
        intro: nil,
        kind: nil,
        lastChapter: nil,
        bookURL: originalURL,
        coverURL: nil,
        tocURL: nil
      ),
      infoHTML: """
        <html><body><h1 class="book-name">预取详情</h1></body></html>
        """
    )

    XCTAssertNil(prefetched.requestPlan)
    XCTAssertEqual(prefetched.book.name, "预取详情")
    XCTAssertEqual(prefetched.book.tocURL, originalURL)
    XCTAssertNotNil(prefetched.tocHTML)
  }

  private var detailHTML: String {
    """
    <html><body>
      <h1 class="book-name">详情阶段书名</h1>
      <span class="book-author">作者：详情作者</span>
      <p class="book-intro">新简介</p>
      <span class="book-kind">科幻,冒险</span>
      <span class="book-word-count">120000</span>
      <span class="book-last-chapter">第二章 回声</span>
      <img class="book-cover" src="cover.svg">
      <a class="toc-link" href="toc.html">目录</a>
    </body></html>
    """
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
          wordCount: HTMLCSSRule(".book-word-count"),
          lastChapter: HTMLCSSRule(".book-last-chapter"),
          coverURL: HTMLCSSRule(".book-cover", value: .src),
          tocURL: HTMLCSSRule(".toc-link", value: .href)
        ),
        toc: TOCRules(
          list: ".chapter",
          name: HTMLCSSRule("a"),
          url: HTMLCSSRule("a", value: .href)
        ),
        content: ContentRules(content: HTMLCSSRule("#content"))
      )
    )
  }
}

private struct BookInfoTransport: HTTPTransport {
  let effectiveURL: URL
  let body: String

  func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
    try HTTPResponse(
      statusCode: 200,
      effectiveURL: HTTPURL(effectiveURL.absoluteString),
      body: HTTPBody(Data(body.utf8))
    )
  }
}

private struct FailingBookInfoTransport: HTTPTransport {
  func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
    throw URLError(.resourceUnavailable)
  }
}
