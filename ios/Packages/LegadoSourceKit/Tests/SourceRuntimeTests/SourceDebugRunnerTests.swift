import Foundation
import XCTest

@testable import SourceRuntime

final class SourceDebugRunnerTests: XCTestCase {
  func testSearchContinuesThroughDetailTOCAndContent() async throws {
    let report = await runner().run("星河")

    XCTAssertEqual(report.outcome, .completed)
    XCTAssertEqual(
      report.stages.map(\.stage),
      [.search, .bookInfo, .toc, .content]
    )
    XCTAssertEqual(
      report.stages.flatMap(\.network).map(\.requestURL),
      [
        "http://debug.test/search?q=%E6%98%9F%E6%B2%B3",
        "http://debug.test/book/1",
        "http://debug.test/toc/1",
        "http://debug.test/content/1",
      ]
    )
    XCTAssertEqual(
      field("preview", in: report.stages.last),
      "第一章正文"
    )
    XCTAssertNoThrow(try JSONEncoder().encode(report))
  }

  func testExploreContinuesFromExplicitDebugURL() async {
    let report = await runner().run(
      "科幻::http://debug.test/explore?page={{page}}"
    )

    XCTAssertEqual(report.outcome, .completed)
    XCTAssertEqual(
      report.stages.map(\.stage),
      [.explore, .bookInfo, .toc, .content]
    )
    XCTAssertEqual(
      report.stages[0].network[0].requestURL,
      "http://debug.test/explore?page=1"
    )
  }

  func testDirectTOCDoesNotInterpretURLAsBookInfo() async {
    let report = await runner().run("++http://debug.test/toc/direct")

    XCTAssertEqual(report.outcome, .completed)
    XCTAssertEqual(report.stages.map(\.stage), [.toc, .content])
    XCTAssertEqual(
      report.stages[0].network[0].requestURL,
      "http://debug.test/toc/direct"
    )
    XCTAssertFalse(
      report.stages.flatMap(\.network).contains {
        $0.requestURL.contains("/book/")
      }
    )
  }

  func testDirectContentStartsAtContentPipeline() async {
    let report = await runner().run(
      "--http://debug.test/content/direct"
    )

    XCTAssertEqual(report.outcome, .completed)
    XCTAssertEqual(report.stages.map(\.stage), [.content])
    XCTAssertEqual(
      report.stages[0].network[0].requestURL,
      "http://debug.test/content/direct"
    )
  }

  func testFailureIncludesStageRuntimeCodeAndNetwork() async {
    let report = await runner(
      transport: DebugTransport(failsAt: "/toc/1")
    ).run("星河")

    XCTAssertEqual(report.outcome, .failed)
    XCTAssertEqual(report.stages.last?.stage, .toc)
    XCTAssertEqual(report.stages.last?.outcome, .failed)
    XCTAssertEqual(report.stages.last?.network.count, 1)
    XCTAssertNotNil(report.stages.last?.failure?.type)
  }

  func testHTMLContentWithDirectTextIsNotDiscarded() async {
    let definition = htmlSourceDefinition()
    let report = await SourceDebugRunner(
      definition: definition,
      transport: DebugHTMLTransport()
    ).run("正文")

    XCTAssertEqual(report.outcome, .completed)
    XCTAssertEqual(
      field("preview", in: report.stages.last),
      "　　直接文本正文"
    )
  }

  // Android Debug.startDebug's frozen continuation is search → detail → TOC
  // → content. P50 freezes the same sequence against SourceLab; this test
  // keeps the iOS report projection attached to that portable contract.
  func testAndroidTruthSourceLabSearchChainProjection() async {
    let report = await SourceDebugRunner(
      definition: androidTruthDefinition(),
      transport: AndroidTruthTransport()
    ).run("真值")

    XCTAssertEqual(report.outcome, .completed)
    XCTAssertEqual(
      report.stages.map(\.stage),
      [.search, .bookInfo, .toc, .content]
    )
    XCTAssertEqual(
      report.stages.flatMap(\.network).map(\.requestURL),
      [
        "http://sourcelab.test/debug/search?q=%E7%9C%9F%E5%80%BC",
        "http://sourcelab.test/debug/book.html",
        "http://sourcelab.test/debug/toc.html",
        "http://sourcelab.test/debug/chapter-1.html",
      ]
    )
    XCTAssertEqual(field("first_name", in: report.stages[0]), "真值之书")
    XCTAssertEqual(field("first_title", in: report.stages[2]), "第一章 真值")
  }

  private func runner(
    transport: any HTTPTransport = DebugTransport()
  ) -> SourceDebugRunner {
    let definition = sourceDefinition()
    return SourceDebugRunner(
      definition: definition,
      exploreDefinition: SourceExploreDefinition(
        source: definition,
        enabled: true,
        catalog: "科幻::http://debug.test/explore?page={{page}}"
      ),
      transport: transport
    )
  }

  private func field(
    _ name: String,
    in stage: SourceDebugStageReport?
  ) -> String? {
    stage?.fields.first(where: { $0.name == name })?.value
  }

  private func sourceDefinition() -> SourceSearchDefinition {
    let listRules = SearchRules(
      list: "@Json:$.books[*]",
      name: HTMLCSSRule("@Json:$.name"),
      author: HTMLCSSRule("@Json:$.author"),
      intro: .optional(nil),
      kind: .optional(nil),
      lastChapter: .optional(nil),
      bookURL: HTMLCSSRule("@Json:$.url", value: .href),
      coverURL: .optional(nil, value: .src)
    )
    return SourceSearchDefinition(
      sourceURL: "http://debug.test",
      sourceName: "调试测试源",
      originOrder: 1,
      runtime: HTMLCSSSourceDefinition(
        searchURLTemplate:
          "http://debug.test/search?q={{key}}",
        search: listRules,
        explore: listRules,
        bookInfo: BookInfoRules(
          name: HTMLCSSRule("@Json:$.name"),
          author: HTMLCSSRule("@Json:$.author"),
          intro: .optional(nil),
          kind: .optional(nil),
          lastChapter: .optional(nil),
          coverURL: .optional(nil, value: .src),
          tocURL: HTMLCSSRule("@Json:$.toc", value: .href)
        ),
        toc: TOCRules(
          list: "@Json:$.chapters[*]",
          name: HTMLCSSRule("@Json:$.name"),
          url: HTMLCSSRule("@Json:$.url", value: .href)
        ),
        content: ContentRules(
          content: HTMLCSSRule("@Json:$.content")
        )
      )
    )
  }

  private func htmlSourceDefinition() -> SourceSearchDefinition {
    SourceSearchDefinition(
      sourceURL: "http://html-debug.test",
      sourceName: "HTML 调试测试源",
      originOrder: 2,
      runtime: HTMLCSSSourceDefinition(
        searchURLTemplate:
          "http://html-debug.test/search?q={{key}}",
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
          name: HTMLCSSRule("h1"),
          author: .optional(nil),
          intro: .optional(nil),
          kind: .optional(nil),
          lastChapter: .optional(nil),
          coverURL: .optional(nil, value: .src),
          tocURL: HTMLCSSRule("a.toc", value: .href)
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

  private func androidTruthDefinition() -> SourceSearchDefinition {
    SourceSearchDefinition(
      sourceURL: "http://sourcelab.test",
      sourceName: "SourceLab Android 调试真值源",
      originOrder: 3,
      runtime: HTMLCSSSourceDefinition(
        searchURLTemplate: "http://sourcelab.test/debug/search?q={{key}}",
        search: SearchRules(
          list: ".book",
          name: HTMLCSSRule(".name"),
          author: HTMLCSSRule(".author"),
          intro: .optional(nil),
          kind: .optional(nil),
          lastChapter: .optional(nil),
          bookURL: HTMLCSSRule("a", value: .href),
          coverURL: .optional(nil, value: .src)
        ),
        bookInfo: BookInfoRules(
          name: HTMLCSSRule("h1"),
          author: HTMLCSSRule(".author"),
          intro: .optional(nil),
          kind: .optional(nil),
          lastChapter: .optional(nil),
          coverURL: .optional(nil, value: .src),
          tocURL: HTMLCSSRule("a.toc", value: .href)
        ),
        toc: TOCRules(
          list: "#toc > li",
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

private actor DebugTransport: HTTPTransport {
  private let failsAt: String?

  init(failsAt: String? = nil) {
    self.failsAt = failsAt
  }

  func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
    let path = URL(string: request.url.absoluteString)?.path ?? ""
    if path == failsAt {
      throw HTTPTransportFailure.connectionFailed
    }
    let body: String
    switch path {
    case "/search", "/explore":
      body =
        #"{"books":[{"name":"星河纪事","author":"天行","url":"/book/1"}]}"#
    case "/book/1":
      body =
        #"{"name":"星河纪事","author":"天行","toc":"/toc/1"}"#
    case "/toc/1", "/toc/direct":
      body =
        #"{"chapters":[{"name":"第一章","url":"/content/1"},{"name":"第二章","url":"/content/2"}]}"#
    case "/content/1", "/content/direct":
      body = #"{"content":"第一章正文"}"#
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

private actor DebugHTMLTransport: HTTPTransport {
  func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
    let path = URL(string: request.url.absoluteString)?.path ?? ""
    let body: String
    switch path {
    case "/search":
      body =
        #"<html><body><div class="book"><span class="name">正文</span><a href="/book">详情</a></div></body></html>"#
    case "/book":
      body =
        #"<html><body><h1>正文</h1><a class="toc" href="/toc">目录</a></body></html>"#
    case "/toc":
      body =
        #"<html><body><div class="chapter"><a href="/content">第一章</a></div></body></html>"#
    case "/content":
      body =
        #"<html><body><article id="content">直接文本正文</article></body></html>"#
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

private actor AndroidTruthTransport: HTTPTransport {
  func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
    let path = URL(string: request.url.absoluteString)?.path ?? ""
    let body: String
    switch path {
    case "/debug/search":
      body = #"<main><article class="book"><a href="/debug/book.html"><span class="name">真值之书</span></a><span class="author">迁移者</span></article></main>"#
    case "/debug/book.html":
      body = #"<main><h1>真值之书</h1><p class="author">迁移者</p><a class="toc" href="/debug/toc.html">目录</a></main>"#
    case "/debug/toc.html":
      body = #"<ol id="toc"><li><a href="/debug/chapter-1.html">第一章 真值</a></li></ol>"#
    case "/debug/chapter-1.html":
      body = #"<main><h1>第一章 真值</h1><article id="content"><p>离线真值正文。</p></article></main>"#
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
