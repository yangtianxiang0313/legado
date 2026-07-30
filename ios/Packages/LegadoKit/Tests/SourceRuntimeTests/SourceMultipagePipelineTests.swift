import Foundation
import XCTest

@testable import SourceRuntime

final class SourceMultipagePipelineTests: XCTestCase {
  func testTOCFollowsSingleNextPageChainAndStopsCycle()
    async throws
  {
    let definition = makeDefinition()
    let transport = MultipageTransport()
    let book = SourceBook(
      name: "星河纪事",
      author: nil,
      intro: nil,
      kind: nil,
      lastChapter: nil,
      bookURL: URL(string: "http://sourcelab.test/book")!,
      coverURL: nil,
      tocURL: nil
    )
    let info =
      #"{"name":"星河纪事","toc":"/toc-1,{\"method\":\"POST\",\"body\":\"page=1\"}"}"#

    let execution = try await SourceTOCPipeline(
      definition: definition,
      transport: transport
    ).chapters(book: book, infoHTML: info)

    XCTAssertEqual(
      execution.chapters.map(\.title),
      ["第一章", "第二章", "第三章"]
    )
    XCTAssertEqual(execution.chapters.map(\.index), [0, 1, 2])
    XCTAssertEqual(
      execution.requests.compactMap {
        $0.body.map {
          String(decoding: $0.bytes, as: UTF8.self)
        }
      },
      ["page=1", "page=2", "page=3"]
    )
  }

  func testContentMergesPagesAndStopsAtNextChapter()
    async throws
  {
    let definition = makeDefinition()
    let transport = MultipageTransport()
    let first = try SourceEndpoint(
      resolving:
        #"/content-1,{"method":"POST","body":"page=1"}"#,
      relativeTo: URL(string: definition.sourceURL)!
    )
    let nextChapter = try SourceEndpoint(
      resolving: "/chapter-2",
      relativeTo: URL(string: definition.sourceURL)!
    )

    let execution = try await SourceContentPipeline(
      definition: definition,
      transport: transport
    ).content(
      endpoint: first,
      nextChapterEndpoint: nextChapter
    )

    XCTAssertEqual(execution.content.content, "第一页\n第二页")
    XCTAssertEqual(execution.requests.count, 2)
    XCTAssertEqual(
      execution.requests.compactMap {
        $0.body.map {
          String(decoding: $0.bytes, as: UTF8.self)
        }
      },
      ["page=1", "page=2"]
    )
  }

  private func makeDefinition() -> SourceSearchDefinition {
    SourceSearchDefinition(
      sourceURL: "http://sourcelab.test",
      sourceName: "分页书源",
      originOrder: 1,
      runtime: HTMLCSSSourceDefinition(
        searchURLTemplate: "http://sourcelab.test/search",
        search: SearchRules(
          list: "@Json:$[*]",
          name: HTMLCSSRule("@Json:$.name"),
          author: .optional(nil),
          intro: .optional(nil),
          kind: .optional(nil),
          lastChapter: .optional(nil),
          bookURL: HTMLCSSRule("@Json:$.url", value: .href),
          coverURL: .optional(nil, value: .src)
        ),
        bookInfo: BookInfoRules(
          name: HTMLCSSRule("@Json:$.name"),
          author: .optional(nil),
          intro: .optional(nil),
          kind: .optional(nil),
          lastChapter: .optional(nil),
          coverURL: .optional(nil, value: .src),
          tocURL: HTMLCSSRule("@Json:$.toc", value: .href)
        ),
        toc: TOCRules(
          list: "@Json:$.chapters[*]",
          name: HTMLCSSRule("@Json:$.name"),
          url: HTMLCSSRule("@Json:$.url", value: .href),
          nextTocURL: HTMLCSSRule(
            "@Json:$.next",
            value: .href
          )
        ),
        content: ContentRules(
          content: HTMLCSSRule("@Json:$.content"),
          nextContentURL: HTMLCSSRule(
            "@Json:$.next",
            value: .href
          )
        )
      )
    )
  }
}

private actor MultipageTransport: HTTPTransport {
  func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
    let body: String
    switch URL(string: request.url.absoluteString)?.path {
    case "/toc-1":
      body =
        #"{"chapters":[{"name":"第一章","url":"/chapter-1"}],"next":"/toc-2,{\"method\":\"POST\",\"body\":\"page=2\"}"}"#
    case "/toc-2":
      body =
        #"{"chapters":[{"name":"第二章","url":"/chapter-2"}],"next":"/toc-3,{\"method\":\"POST\",\"body\":\"page=3\"}"}"#
    case "/toc-3":
      body =
        #"{"chapters":[{"name":"第三章","url":"/chapter-3"}],"next":"/toc-1,{\"method\":\"POST\",\"body\":\"page=1\"}"}"#
    case "/content-1":
      body =
        #"{"content":"第一页","next":"/content-2,{\"method\":\"POST\",\"body\":\"page=2\"}"}"#
    case "/content-2":
      body =
        #"{"content":"第二页","next":"/chapter-2"}"#
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
