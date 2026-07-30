import Foundation
import XCTest

@testable import SourceRuntime

final class SourceProductRequestIntegrationTests: XCTestCase {
  func testSourceHeadersAreInheritedAndURLHeadersOverrideExactKey()
    async throws
  {
    let definition = try makeDefinition(
      searchURL:
        #"http://sourcelab.test/search?q={{key}},{"headers":{"X-Source":"option","x-case":"lower"}}"#,
      sourceHeaders: [
        try SourceHeaderField(name: "X-Source", value: "source"),
        try SourceHeaderField(name: "X-Case", value: "upper"),
      ]
    )
    let transport = HeaderRecordingTransport()

    let execution = try await SourceSearchPipeline(
      definition: definition,
      transport: transport
    ).search(SourceSearchInput(keyword: "星河", page: 1))

    XCTAssertEqual(execution.books.map(\.name), ["星河纪事"])
    XCTAssertEqual(
      execution.requestPlan.request.headers.values(for: "X-Source"),
      ["option"]
    )
    XCTAssertEqual(
      execution.requestPlan.request.headers.values(for: "X-Case"),
      ["upper", "lower"]
    )
    let recorded = await transport.requests()
    XCTAssertEqual(recorded, [execution.requestPlan.request])
  }

  func testSourceHeadersReachSearchDetailTOCAndContentRequests()
    async throws
  {
    let definition = try makeDefinition(
      searchURL: "http://sourcelab.test/search?q={{key}}",
      sourceHeaders: [
        try SourceHeaderField(
          name: "User-Agent",
          value: "Legado-iOS-Source"
        ),
        try SourceHeaderField(
          name: "Referer",
          value: "http://sourcelab.test/origin"
        ),
      ]
    )
    let transport = HeaderRecordingTransport()
    let bookURL = URL(string: "http://sourcelab.test/book")!
    let book = SourceBook(
      name: "星河纪事",
      author: nil,
      intro: nil,
      kind: nil,
      lastChapter: nil,
      bookURL: bookURL,
      coverURL: nil,
      tocURL: nil
    )

    _ = try await SourceSearchPipeline(
      definition: definition,
      transport: transport
    ).search(SourceSearchInput(keyword: "星河", page: 1))
    _ = try await SourceBookInfoPipeline(
      definition: definition,
      transport: transport
    ).load(book: book)
    _ = try await SourceTOCPipeline(
      definition: definition,
      transport: transport
    ).chapters(book: book)
    _ = try await SourceContentPipeline(
      definition: definition,
      transport: transport
    ).content(chapterURL: "http://sourcelab.test/chapter-1")

    let requests = await transport.requests()
    XCTAssertEqual(requests.count, 5)
    for request in requests {
      XCTAssertEqual(
        request.headers.values(for: "User-Agent"),
        ["Legado-iOS-Source"]
      )
      XCTAssertEqual(
        request.headers.values(for: "Referer"),
        ["http://sourcelab.test/origin"]
      )
    }
  }

  func testEnabledCookieSessionIsSharedAndPersistentLayerRestores()
    async throws
  {
    let persistence = MemoryCookiePersistence(
      values: [
        "sourcelab.test": "persisted=stored; shared=stored"
      ]
    )
    let cookieStore = SourceCookieStore(persistence: persistence)
    let definition = SourceSearchDefinition(
      sourceURL: "http://sourcelab.test",
      sourceName: "Cookie 书源",
      originOrder: 1,
      sourceHeaders: [
        try SourceHeaderField(
          name: "Cookie",
          value: "explicit=source; shared=explicit"
        )
      ],
      enabledCookieJar: true,
      runtime: try makeDefinition(
        searchURL: "http://sourcelab.test/search?q={{key}}",
        sourceHeaders: []
      ).runtime
    )
    let transport = CookieRecordingTransport()
    let pipeline = SourceSearchPipeline(
      definition: definition,
      transport: transport,
      cookieStore: cookieStore
    )

    _ = try await pipeline.search(
      SourceSearchInput(keyword: "第一次", page: 1)
    )
    _ = try await pipeline.search(
      SourceSearchInput(keyword: "第二次", page: 1)
    )

    let requests = await transport.requests()
    XCTAssertEqual(
      requests[0].headers.values(for: "cookie"),
      ["persisted=stored; shared=stored; explicit=source"]
    )
    XCTAssertEqual(
      requests[1].headers.values(for: "cookie"),
      [
        "persisted=stored; shared=session; remember=server; "
          + "session=memory; explicit=source"
      ]
    )
    let restored = SourceCookieStore(persistence: persistence)
    let snapshot = try await restored.snapshot(
      for: try HTTPURL("http://sourcelab.test/search")
    )
    XCTAssertEqual(
      snapshot.persistentCookie,
      "persisted=stored; shared=stored; remember=server"
    )
    XCTAssertNil(snapshot.sessionCookie)
  }

  func testProductRetryStopsAfterSuccess() async throws {
    let definition = try makeDefinition(
      searchURL:
        #"http://sourcelab.test/search?q={{key}},{"retry":2}"#,
      sourceHeaders: []
    )
    let transport = RetryRecordingTransport(
      statusCodes: [503, 200, 503]
    )

    let execution = try await SourceSearchPipeline(
      definition: definition,
      transport: transport
    ).search(SourceSearchInput(keyword: "星河", page: 1))

    XCTAssertEqual(execution.books.map(\.name), ["星河纪事"])
    let requestCount = await transport.requestCount()
    XCTAssertEqual(requestCount, 2)
  }

  func testProductRetryUsesInitialAttemptPlusConfiguredRetries()
    async throws
  {
    let definition = try makeDefinition(
      searchURL:
        #"http://sourcelab.test/search?q={{key}},{"retry":2}"#,
      sourceHeaders: []
    )
    let transport = RetryRecordingTransport(
      statusCodes: [503, 503, 503, 200]
    )

    _ = try await SourceSearchPipeline(
      definition: definition,
      transport: transport
    ).search(SourceSearchInput(keyword: "星河", page: 1))

    let requestCount = await transport.requestCount()
    XCTAssertEqual(requestCount, 3)
  }

  private func makeDefinition(
    searchURL: String,
    sourceHeaders: [SourceHeaderField]
  ) throws -> SourceSearchDefinition {
    SourceSearchDefinition(
      sourceURL: "http://sourcelab.test",
      sourceName: "Header 书源",
      originOrder: 1,
      sourceHeaders: sourceHeaders,
      runtime: HTMLCSSSourceDefinition(
        searchURLTemplate: searchURL,
        search: SearchRules(
          list: ".book",
          name: HTMLCSSRule(".name"),
          author: .optional(nil),
          intro: .optional(nil),
          kind: .optional(nil),
          lastChapter: .optional(nil),
          bookURL: HTMLCSSRule("a", value: .href),
          coverURL: .optional(nil, value: .src)
        ),
        bookInfo: BookInfoRules(
          name: HTMLCSSRule(".name"),
          author: .optional(nil),
          intro: .optional(nil),
          kind: .optional(nil),
          lastChapter: .optional(nil),
          coverURL: .optional(nil, value: .src),
          tocURL: HTMLCSSRule(".toc", value: .href)
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

private actor HeaderRecordingTransport: HTTPTransport {
  private var recorded: [HTTPRequest] = []

  func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
    recorded.append(request)
    let path = URL(string: request.url.absoluteString)?.path ?? ""
    let body: String
    switch path {
    case "/search":
      body = """
        <html><body>
          <article class="book">
            <span class="name">星河纪事</span>
            <a href="/book"></a>
          </article>
        </body></html>
        """
    case "/book":
      body = """
        <html><body>
          <h1 class="name">星河纪事</h1>
          <a class="toc" href="/toc"></a>
        </body></html>
        """
    case "/toc":
      body = """
        <html><body>
          <div class="chapter">
            <a href="/chapter-1">第一章 启航</a>
          </div>
        </body></html>
        """
    case "/chapter-1":
      body = """
        <html><body>
          <div id="content"><p>正文</p></div>
        </body></html>
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

  func requests() -> [HTTPRequest] {
    recorded
  }
}

private actor MemoryCookiePersistence: SourceCookiePersisting {
  private var values: [String: String]

  init(values: [String: String]) {
    self.values = values
  }

  func loadPersistentCookie(
    for domain: String
  ) async throws -> String? {
    values[domain]
  }

  func savePersistentCookie(
    _ cookie: String?,
    for domain: String
  ) async throws {
    values[domain] = cookie
  }
}

private actor CookieRecordingTransport: HTTPTransport {
  private var recorded: [HTTPRequest] = []

  func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
    recorded.append(request)
    return try HTTPResponse(
      statusCode: 200,
      effectiveURL: request.url,
      headers: HTTPHeaders([
        try HTTPHeader(
          name: "Set-Cookie",
          value: "remember=server; Max-Age=3600"
        ),
        try HTTPHeader(
          name: "Set-Cookie",
          value: "session=memory; Path=/"
        ),
        try HTTPHeader(
          name: "Set-Cookie",
          value: "shared=session; Path=/"
        ),
      ]),
      body: HTTPBody(
        Data(
          """
          <html><body>
            <article class="book">
              <span class="name">星河纪事</span>
              <a href="/book"></a>
            </article>
          </body></html>
          """.utf8
        )
      )
    )
  }

  func requests() -> [HTTPRequest] {
    recorded
  }
}

private actor RetryRecordingTransport: HTTPTransport {
  private let statusCodes: [Int]
  private var count = 0

  init(statusCodes: [Int]) {
    self.statusCodes = statusCodes
  }

  func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
    let index = min(count, statusCodes.count - 1)
    let statusCode = statusCodes[index]
    count += 1
    return try HTTPResponse(
      statusCode: statusCode,
      effectiveURL: request.url,
      body: HTTPBody(
        Data(
          """
          <html><body>
            <article class="book">
              <span class="name">星河纪事</span>
              <a href="/book"></a>
            </article>
          </body></html>
          """.utf8
        )
      )
    )
  }

  func requestCount() -> Int {
    count
  }
}
