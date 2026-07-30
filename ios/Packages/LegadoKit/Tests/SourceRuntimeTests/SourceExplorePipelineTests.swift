import Foundation
import XCTest

@testable import SourceRuntime

final class SourceExplorePipelineTests: XCTestCase {
  func testCategoryPageExploreRulesAndReverseMatchAndroid() async throws {
    let pipeline = SourceExplorePipeline(
      definition: SourceExploreDefinition(
        source: source(),
        enabled: true,
        catalog:
          "奇幻::http://sourcelab.test/pipeline/explore/"
          + "{{page}}?category=fantasy"
      ),
      transport: ExploreTransport(body: html)
    )
    let categories = try pipeline.categories()
    let execution = try await pipeline.explore(
      SourceExploreInput(category: categories[0], page: 2)
    )

    XCTAssertEqual(categories.map(\.title), ["奇幻"])
    XCTAssertEqual(
      execution.requestPlan.request.url.absoluteString,
      "http://sourcelab.test/pipeline/explore/2?category=fantasy"
    )
    XCTAssertEqual(
      execution.books.map(\.name),
      ["龙眠之地", "森林尽头"]
    )
    XCTAssertEqual(
      execution.books.map(\.author),
      ["云岚", "青木"]
    )
    XCTAssertEqual(
      execution.books.map(\.wordCount),
      ["12万字", "8.6万字"]
    )
    XCTAssertEqual(
      execution.books[0].coverURL,
      "http://sourcelab.test/pipeline/explore/covers/dragon.jpg"
    )
  }

  private func source() -> SourceSearchDefinition {
    let searchRules = SearchRules(
      list: ".wrong-search-item",
      name: HTMLCSSRule(".wrong-name"),
      author: HTMLCSSRule(".wrong-author"),
      intro: .optional(nil),
      kind: .optional(nil),
      lastChapter: .optional(nil),
      bookURL: HTMLCSSRule("a", value: .href),
      coverURL: .optional(nil, value: .src)
    )
    let exploreRules = SearchRules(
      list: "-.explore-item",
      name: HTMLCSSRule(".book-name"),
      author: HTMLCSSRule(".book-author"),
      intro: HTMLCSSRule(".book-intro"),
      kind: HTMLCSSRule(".book-kind"),
      wordCount: HTMLCSSRule(".book-word-count"),
      lastChapter: HTMLCSSRule(".book-last-chapter"),
      bookURL: HTMLCSSRule("a.book-link", value: .href),
      coverURL: HTMLCSSRule("img.book-cover", value: .src)
    )
    return SourceSearchDefinition(
      sourceURL: "http://sourcelab.test",
      sourceName: "SourceLab 发现流水线源",
      originOrder: 41,
      runtime: HTMLCSSSourceDefinition(
        searchURLTemplate:
          "http://sourcelab.test/unused-search?q={{key}}",
        search: searchRules,
        explore: exploreRules,
        bookInfo: BookInfoRules(
          name: HTMLCSSRule("h1"),
          author: .optional(nil),
          intro: .optional(nil),
          kind: .optional(nil),
          lastChapter: .optional(nil),
          coverURL: .optional(nil, value: .src),
          tocURL: .optional(nil, value: .href)
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

  private var html: String {
    """
    <html><body>
      <article class="explore-item">
        <a class="book-link" href="/books/forest/index.html"></a>
        <span class="book-name">森林尽头</span>
        <span class="book-author">作者：青木</span>
        <span class="book-word-count">86000</span>
      </article>
      <article class="explore-item">
        <a class="book-link" href="/books/dragon/index.html"></a>
        <span class="book-name">龙眠之地</span>
        <span class="book-author">云岚</span>
        <span class="book-word-count">12万字</span>
        <img class="book-cover" src="covers/dragon.jpg">
      </article>
    </body></html>
    """
  }
}

private struct ExploreTransport: HTTPTransport {
  let body: String

  func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
    try HTTPResponse(
      statusCode: 200,
      effectiveURL: request.url,
      body: HTTPBody(Data(body.utf8))
    )
  }
}
