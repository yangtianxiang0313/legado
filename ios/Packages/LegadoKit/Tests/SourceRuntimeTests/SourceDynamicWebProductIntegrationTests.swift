import Foundation
@testable import SourceRuntime
import XCTest

final class SourceDynamicWebProductIntegrationTests: XCTestCase {
  func testSearchExploreAndDetailUseDynamicPageResponse()
    async throws
  {
    let pagePort = ProductDynamicPagePort()
    let definition = dynamicDefinition()
    let transport = RejectingHTTPTransport()

    let search = try await SourceSearchPipeline(
      definition: definition,
      transport: transport,
      dynamicWebPagePort: pagePort
    ).search(SourceSearchInput(keyword: "星河", page: 1))
    let explore = try await SourceExplorePipeline(
      definition: SourceExploreDefinition(
        source: definition,
        enabled: true,
        catalog: ""
      ),
      transport: transport,
      dynamicWebPagePort: pagePort
    ).explore(
      SourceExploreInput(
        category: SourceExploreCategory(
          title: "分类",
          urlTemplate:
            #"http://source.test/explore,{"useWebView":true}"#
        ),
        page: 1
      )
    )
    let detail = try await SourceBookInfoPipeline(
      definition: definition,
      transport: transport,
      dynamicWebPagePort: pagePort
    ).load(
      book: SourceBook(
        name: "星河",
        author: "林舟",
        intro: nil,
        kind: nil,
        lastChapter: nil,
        bookEndpoint: try SourceEndpoint(
          resolving:
            #"http://source.test/book,{"useWebView":true}"#,
          relativeTo: URL(string: definition.sourceURL)!
        ),
        coverURL: nil,
        tocEndpoint: nil
      )
    )

    XCTAssertEqual(search.books.map(\.name), ["搜索结果"])
    XCTAssertEqual(explore.books.map(\.name), ["发现结果"])
    XCTAssertEqual(detail.book.name, "详情书名")
    let requestedPaths = await pagePort.requestedPaths()
    XCTAssertEqual(
      requestedPaths,
      ["/search", "/explore", "/book"]
    )
  }

  func testTOCAndContentUseDynamicPageAndContentConfiguration()
    async throws
  {
    let pagePort = ProductDynamicPagePort()
    let definition = dynamicDefinition()
    let transport = RejectingHTTPTransport()
    let book = SourceBook(
      name: "星河",
      author: "林舟",
      intro: nil,
      kind: nil,
      lastChapter: nil,
      bookEndpoint: try SourceEndpoint(
        resolving:
          #"http://source.test/book,{"useWebView":true}"#,
        relativeTo: URL(string: definition.sourceURL)!
      ),
      coverURL: nil,
      tocEndpoint: nil
    )

    let toc = try await SourceTOCPipeline(
      definition: definition,
      transport: transport,
      dynamicWebPagePort: pagePort
    ).chapters(book: book)
    let content = try await SourceContentPipeline(
      definition: definition,
      transport: transport,
      dynamicWebPagePort: pagePort
    ).content(
      chapterURL:
        #"http://source.test/chapter,{"useWebView":true}"#
    )

    XCTAssertEqual(toc.chapters.map(\.title), ["第一章"])
    XCTAssertTrue(content.content.content.contains("动态正文"))
    let captured = await pagePort.requests()
    let contentRequest = try XCTUnwrap(captured.last)
    XCTAssertEqual(contentRequest.javaScript, "window.content()")
    XCTAssertEqual(contentRequest.sourceRegex, #"/chapter/.*\.js"#)
  }

  private func dynamicDefinition() -> SourceSearchDefinition {
    SourceSearchDefinition(
      sourceURL: "http://source.test",
      sourceName: "动态书源",
      originOrder: 0,
      runtime: HTMLCSSSourceDefinition(
        searchURLTemplate:
          #"http://source.test/search,{"useWebView":true}"#,
        search: listRules(),
        explore: listRules(),
        bookInfo: BookInfoRules(
          name: HTMLCSSRule("h1"),
          author: .optional(".author"),
          intro: .optional(nil),
          kind: .optional(nil),
          lastChapter: .optional(nil),
          coverURL: .optional(nil),
          tocURL: HTMLCSSRule("a.toc", value: .href),
          allowsRename: true
        ),
        toc: TOCRules(
          list: "li.chapter",
          name: HTMLCSSRule("a"),
          url: HTMLCSSRule("a", value: .href)
        ),
        content: ContentRules(
          content: HTMLCSSRule("article"),
          nextContentURL: nil,
          webJS: "window.content()",
          sourceRegex: #"/chapter/.*\.js"#
        )
      )
    )
  }

  private func listRules() -> SearchRules {
    SearchRules(
      list: "li.book",
      name: HTMLCSSRule("a.name"),
      author: .optional(nil),
      intro: .optional(nil),
      kind: .optional(nil),
      lastChapter: .optional(nil),
      bookURL: HTMLCSSRule("a.name", value: .href),
      coverURL: .optional(nil)
    )
  }
}

private actor ProductDynamicPagePort: SourceDynamicWebPagePort {
  private var captured: [SourceDynamicWebPageRequest] = []

  func execute(
    _ request: SourceDynamicWebPageRequest
  ) async throws -> SourceDynamicWebPageResult {
    captured.append(request)
    let body: String
    switch request.url.absoluteString {
    case let value where value.contains("/search"):
      body = listHTML(name: "搜索结果", path: "/book")
    case let value where value.contains("/explore"):
      body = listHTML(name: "发现结果", path: "/book")
    case let value where value.contains("/book"):
      body = """
        <html><body>
          <h1>详情书名</h1><span class="author">林舟</span>
          <a class="toc" href="/toc,{&quot;useWebView&quot;:true}">目录</a>
        </body></html>
        """
    case let value where value.contains("/toc"):
      body = """
        <html><body><ul>
          <li class="chapter"><a href="/chapter">第一章</a></li>
        </ul></body></html>
        """
    default:
      body = """
        <html><body><article><p>动态正文</p></article></body></html>
        """
    }
    return SourceDynamicWebPageResult(
      finalURL: request.url,
      value: body,
      completionKind: .javaScript,
      webCookie: nil
    )
  }

  func requests() -> [SourceDynamicWebPageRequest] {
    captured
  }

  func requestedPaths() -> [String] {
    captured.compactMap {
      URL(string: $0.url.absoluteString)?.path
    }
  }

  private func listHTML(name: String, path: String) -> String {
    """
    <html><body><ul>
      <li class="book"><a class="name" href="\(path)">\(name)</a></li>
    </ul></body></html>
    """
  }
}

private struct RejectingHTTPTransport: HTTPTransport {
  struct UnexpectedRequest: Error {}

  func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
    throw UnexpectedRequest()
  }
}
