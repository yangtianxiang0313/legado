import AppUseCases
import Foundation
import SourceRuntime
import XCTest

final class RSSContentStarTests: XCTestCase {
  func testRuleContentUsesArticleURLAndSourceHeaders() async throws {
    let transport = RSSContentTransport()
    let loader = SourceRuntimeRSSContentLoader(transport: transport)
    let source = RSSSource(
      sourceURL: "https://rss.example.com/feed",
      header: #"{"Referer":"https://rss.example.com"}"#,
      ruleContent: "@Json:$.content"
    )
    let article = RSSArticleItem(
      origin: source.sourceURL,
      sort: "新闻",
      title: "正文",
      link: "/article/1"
    )

    let content = try await loader.load(source: source, article: article)

    XCTAssertEqual(content, "Android 规则解析正文")
    let request = await transport.recordedRequest()
    XCTAssertEqual(request?.url.absoluteString, "https://rss.example.com/article/1")
    XCTAssertEqual(request?.headers.values(for: "Referer"), ["https://rss.example.com"])
  }

  @MainActor
  func testToggleStarPersistsAndroidCompositeKeyFields() async throws {
    let repository = MemoryRSSRepository()
    let store = RSSStore(repository: repository)
    let article = RSSArticleItem(
      origin: "https://rss.example.com/feed",
      sort: "新闻",
      title: "收藏文章",
      link: "https://rss.example.com/article/1",
      description: "摘要"
    )

    await store.toggleStar(article)
    XCTAssertTrue(store.isStarred(article))
    let star = try XCTUnwrap(store.stars.first)
    XCTAssertEqual(star.origin, article.origin)
    XCTAssertEqual(star.link, article.link)
    XCTAssertEqual(star.sort, article.sort)

    await store.toggleStar(article)
    XCTAssertFalse(store.isStarred(article))
  }
}

private actor RSSContentTransport: HTTPTransport {
  private var request: HTTPRequest?

  func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
    self.request = request
    return try HTTPResponse(
      statusCode: 200,
      effectiveURL: request.url,
      body: HTTPBody(Data(#"{"content":"Android 规则解析正文"}"#.utf8))
    )
  }

  func recordedRequest() -> HTTPRequest? { request }
}

private actor MemoryRSSRepository: RSSRepository {
  private var sources: [RSSSource] = []
  private var stars: [RSSStar] = []

  func rssSources() async throws -> [RSSSource] { sources }
  func rssStars() async throws -> [RSSStar] { stars }

  func upsertRSSSource(_ source: RSSSource) async throws {
    sources.removeAll { $0.sourceURL == source.sourceURL }
    sources.append(source)
  }

  func upsertRSSStar(_ star: RSSStar) async throws {
    stars.removeAll { $0.origin == star.origin && $0.link == star.link }
    stars.append(star)
  }

  func deleteRSSStar(origin: String, link: String) async throws {
    stars.removeAll { $0.origin == origin && $0.link == link }
  }
}
