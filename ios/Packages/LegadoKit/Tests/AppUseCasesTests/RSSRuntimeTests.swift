import AppUseCases
import Foundation
import SourceRuntime
import XCTest

final class RSSRuntimeTests: XCTestCase {
  func testAndroidRuleFeedParsesFieldsAndPagination() async throws {
    let transport = RSSFixtureTransport(body: #"""
    {
      "items": [
        {"title":"第二篇","link":"/article/2","date":"今天","summary":"摘要二","image":"/2.png"},
        {"title":"第一篇","link":"/article/1","date":"昨天","summary":"摘要一","image":"/1.png"},
        {"title":"","link":"/ignored"}
      ]
    }
    """#)
    let loader = SourceRuntimeRSSArticleLoader(transport: transport)
    let source = RSSSource(
      sourceURL: "https://rss.example.com/feed",
      sourceName: "规则源",
      header: #"{"X-Source":"android"}"#,
      ruleArticles: "-@Json:$.items[*]",
      ruleNextPage: "PAGE",
      ruleTitle: "@Json:$.title",
      rulePubDate: "@Json:$.date",
      ruleDescription: "@Json:$.summary",
      ruleImage: "@Json:$.image",
      ruleLink: "@Json:$.link"
    )

    let page = try await loader.load(
      source: source,
      sortName: "规则源",
      sortURL: "https://rss.example.com/list?page={{page}}",
      page: 2
    )

    XCTAssertEqual(page.articles.map(\.title), ["第一篇", "第二篇"])
    XCTAssertEqual(page.articles.first?.link, "https://rss.example.com/article/1")
    XCTAssertEqual(page.articles.first?.image, "https://rss.example.com/1.png")
    XCTAssertEqual(page.nextPageURL, "https://rss.example.com/list?page={{page}}")
    let request = await transport.lastRequest()
    XCTAssertEqual(request?.url.absoluteString, "https://rss.example.com/list?page=2")
    XCTAssertEqual(
      request?.headers.values(for: "X-Source").first,
      "android"
    )
  }

  func testDefaultRSSItemParserMatchesAndroidFallback() async throws {
    let transport = RSSFixtureTransport(body: #"""
      <?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/">
        <channel><item>
          <title>默认文章</title>
          <link>https://rss.example.com/default</link>
          <pubDate>Mon, 03 Aug 2026 10:00:00 GMT</pubDate>
          <description><![CDATA[摘要<img src="https://img.example.com/cover.png"/>]]></description>
          <content:encoded><![CDATA[完整正文]]></content:encoded>
        </item></channel>
      </rss>
      """#)
    let loader = SourceRuntimeRSSArticleLoader(transport: transport)
    let source = RSSSource(sourceURL: "https://rss.example.com/feed")

    let page = try await loader.load(
      source: source,
      sortName: "默认源",
      sortURL: source.sourceURL,
      page: 1
    )

    XCTAssertEqual(page.articles.count, 1)
    XCTAssertEqual(page.articles[0].title, "默认文章")
    XCTAssertEqual(page.articles[0].content, "完整正文")
    XCTAssertEqual(page.articles[0].image, "https://img.example.com/cover.png")
    XCTAssertNil(page.nextPageURL)
  }
}

private actor RSSFixtureTransport: HTTPTransport {
  private let body: String
  private var request: HTTPRequest?

  init(body: String) { self.body = body }

  func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
    self.request = request
    return try HTTPResponse(
      statusCode: 200,
      effectiveURL: request.url,
      body: HTTPBody(Data(body.utf8))
    )
  }

  func lastRequest() -> HTTPRequest? { request }
}
