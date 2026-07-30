import XCTest

@testable import SourceRuntime

final class SourceVariableProductIntegrationTests: XCTestCase {
  func testVariablesPropagateAcrossSearchDetailTOCAndContent()
    async throws
  {
    let definition = SourceSearchDefinition(
      sourceURL: "http://sourcelab.test",
      sourceName: "变量书源",
      originOrder: 1,
      runtime: HTMLCSSSourceDefinition(
        searchURLTemplate:
          #"http://sourcelab.test/search?seed={{java.put('seed','from-url')}}"#,
        search: SearchRules(
          list: "@Json:$[*]",
          name: HTMLCSSRule(
            #"@put:{"detailToken":"@Json:$.token"}@Json:$.name"#
          ),
          author: HTMLCSSRule(
            "@js:java.get('detailToken')"
          ),
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
          tocURL: HTMLCSSRule(
            #"@put:{"tocToken":"@Json:$.tocToken"}@Json:$.toc"#,
            value: .href
          )
        ),
        toc: TOCRules(
          list: "@Json:$.chapters[*]",
          name: HTMLCSSRule(
            #"@put:{"chapterToken":"@Json:$.chapterToken"}@Json:$.name"#
          ),
          url: HTMLCSSRule("@Json:$.url", value: .href)
        ),
        content: ContentRules(
          content: HTMLCSSRule(
            "@js:java.get('chapterToken')"
          )
        )
      )
    )
    let transport = VariableProductTransport()
    let search = try await SourceSearchPipeline(
      definition: definition,
      transport: transport
    ).search(SourceSearchInput(keyword: "星河", page: 1))
    let found = try XCTUnwrap(search.books.first)
    let book = SourceBook(
      name: found.name,
      author: found.author,
      intro: found.intro,
      kind: found.kind,
      lastChapter: found.lastChapter,
      bookEndpoint: try SourceEndpoint(
        resolving: found.bookRequestExpression,
        relativeTo: URL(string: definition.sourceURL)!
      ),
      coverURL: nil,
      tocEndpoint: nil,
      variables: found.variables
    )
    let toc = try await SourceTOCPipeline(
      definition: definition,
      transport: transport
    ).chapters(book: book)
    let chapter = try XCTUnwrap(toc.chapters.first)
    let content = try await SourceContentPipeline(
      definition: definition,
      transport: transport
    ).content(
      endpoint: chapter.endpoint,
      bookVariables: toc.book.variables,
      chapterVariables: chapter.variables
    )

    XCTAssertEqual(found.author, "from-search")
    XCTAssertEqual(found.variables["seed"], "from-url")
    XCTAssertEqual(found.variables["detailToken"], "from-search")
    XCTAssertEqual(toc.book.variables["tocToken"], "from-detail")
    XCTAssertEqual(
      chapter.variables["chapterToken"],
      "from-chapter"
    )
    XCTAssertEqual(content.content.content, "from-chapter")
  }

  func testPutRuleIsVisibleToLaterFieldInSameContext()
    async throws
  {
    let store = SourceVariableStore(policy: .androidRuleData)
    let resolver = SourceVariableResolver(
      role: .rule,
      scopes: SourceVariableScopes(ruleData: store)
    )
    let evaluator = SourceVariableRuleEvaluator(
      content: #"{"name":"星河纪事","token":"shared-token"}"#,
      resolver: resolver
    )

    let name = try await evaluator.getString(
      #"@put:{"token":"@Json:$.token"}@Json:$.name"#
    )
    let token = try await evaluator.getString(
      "@js:java.get('token')"
    )

    XCTAssertEqual(name, "星河纪事")
    XCTAssertEqual(token, "shared-token")
  }

  func testJavaPutIsImmediateAndIndependentContextIsIsolated()
    async throws
  {
    let shared = SourceVariableStore(policy: .androidRuleData)
    let sharedResolver = SourceVariableResolver(
      role: .rule,
      scopes: SourceVariableScopes(ruleData: shared)
    )
    let first = SourceVariableRuleEvaluator(
      content: "response",
      resolver: sharedResolver
    )
    let written = try await first.getString(
      "@js:java.put('token', result.toString())"
    )
    XCTAssertEqual(written, "response")

    let isolated = SourceVariableRuleEvaluator(
      content: "other",
      resolver: SourceVariableResolver(
        role: .rule,
        scopes: SourceVariableScopes(
          ruleData: SourceVariableStore(
            policy: .androidRuleData
          )
        )
      )
    )
    let sharedValue = try await first.getString(
      "@js:java.get('token')"
    )
    let isolatedValue = try await isolated.getString(
      "@js:java.get('token')"
    )
    XCTAssertEqual(sharedValue, "response")
    XCTAssertEqual(isolatedValue, "")
  }
}

private actor VariableProductTransport: HTTPTransport {
  func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
    let body: String
    switch URL(string: request.url.absoluteString)?.path {
    case "/search":
      body =
        #"[{"name":"星河纪事","token":"from-search","url":"/book"}]"#
    case "/book":
      body =
        #"{"name":"星河纪事","tocToken":"from-detail","toc":"/toc"}"#
    case "/toc":
      body =
        #"{"chapters":[{"name":"第一章","chapterToken":"from-chapter","url":"/content"}]}"#
    case "/content":
      body = #"{"unused":"value"}"#
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
