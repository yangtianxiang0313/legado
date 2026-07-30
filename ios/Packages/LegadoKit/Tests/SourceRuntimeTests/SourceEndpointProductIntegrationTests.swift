import Foundation
import XCTest

@testable import SourceRuntime

final class SourceEndpointProductIntegrationTests: XCTestCase {
  func testDetailTOCAndContentUsePreservedRequestOptions()
    async throws
  {
    let definition = SourceSearchDefinition(
      sourceURL: "http://sourcelab.test",
      sourceName: "端点书源",
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
          url: HTMLCSSRule("@Json:$.url", value: .href)
        ),
        content: ContentRules(
          content: HTMLCSSRule("@Json:$.content")
        )
      )
    )
    let bookEndpoint = try SourceEndpoint(
      resolving:
        #"/book,{"method":"POST","body":"book=1","header":{"X-Stage":"detail"}}"#,
      relativeTo: URL(string: definition.sourceURL)!
    )
    let book = SourceBook(
      name: "星河纪事",
      author: nil,
      intro: nil,
      kind: nil,
      lastChapter: nil,
      bookEndpoint: bookEndpoint,
      coverURL: nil,
      tocEndpoint: nil
    )
    let transport = EndpointProductTransport()

    let toc = try await SourceTOCPipeline(
      definition: definition,
      transport: transport
    ).chapters(book: book)
    let chapter = try XCTUnwrap(toc.chapters.first)
    let content = try await SourceContentPipeline(
      definition: definition,
      transport: transport
    ).content(endpoint: chapter.endpoint)

    XCTAssertEqual(content.content.content, "正文")
    XCTAssertEqual(
      toc.book.tocEndpoint?.requestExpression,
      #"\#(definition.sourceURL)/toc,{"method":"POST","body":"toc=1","header":{"X-Stage":"toc"}}"#
    )
    XCTAssertEqual(
      chapter.endpoint.requestExpression,
      #"\#(definition.sourceURL)/content,{"method":"POST","body":"chapter=1","header":{"X-Stage":"content"}}"#
    )

    let requests = await transport.requests()
    XCTAssertEqual(requests.map(\.method), [.post, .post, .post])
    XCTAssertEqual(
      requests.map { $0.body.map { String(decoding: $0.bytes, as: UTF8.self) } },
      ["book=1", "toc=1", "chapter=1"]
    )
    XCTAssertEqual(
      requests.map { $0.headers.values(for: "X-Stage").first },
      ["detail", "toc", "content"]
    )
  }
}

private actor EndpointProductTransport: HTTPTransport {
  private var recorded: [HTTPRequest] = []

  func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
    recorded.append(request)
    let body: String
    switch URL(string: request.url.absoluteString)?.path {
    case "/book":
      body =
        #"{"name":"星河纪事","toc":"/toc,{\"method\":\"POST\",\"body\":\"toc=1\",\"header\":{\"X-Stage\":\"toc\"}}"}"#
    case "/toc":
      body =
        #"{"chapters":[{"name":"第一章","url":"/content,{\"method\":\"POST\",\"body\":\"chapter=1\",\"header\":{\"X-Stage\":\"content\"}}"}]}"#
    case "/content":
      body = #"{"content":"正文"}"#
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
