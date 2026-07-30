import Foundation
@testable import SourceRuntime
import XCTest

final class SourceScriptProductIntegrationTests: XCTestCase {
  func testSearchExploreDetailTOCAndContentShareInjectedScriptRuntime()
    async throws
  {
    let scriptRuntime = ProductScriptRuntime()
    let definition = scriptDefinition()
    let transport = ScriptProductTransport()

    let search = try await SourceSearchPipeline(
      definition: definition,
      transport: transport,
      scriptRuntime: scriptRuntime
    ).search(SourceSearchInput(keyword: "脚本", page: 1))
    let explore = try await SourceExplorePipeline(
      definition: SourceExploreDefinition(
        source: definition,
        enabled: true,
        catalog: ""
      ),
      transport: transport,
      scriptRuntime: scriptRuntime
    ).explore(
      SourceExploreInput(
        category: SourceExploreCategory(
          title: "脚本分类",
          urlTemplate: "http://script.test/explore"
        ),
        page: 1
      )
    )
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
      transport: transport,
      scriptRuntime: scriptRuntime
    ).chapters(book: book)
    let chapter = try XCTUnwrap(toc.chapters.first)
    let content = try await SourceContentPipeline(
      definition: definition,
      transport: transport,
      scriptRuntime: scriptRuntime
    ).content(
      endpoint: chapter.endpoint,
      bookVariables: toc.book.variables,
      chapterVariables: chapter.variables
    )
    let sessionIDs = await scriptRuntime.sessionIDs()

    XCTAssertEqual(found.name, "搜索脚本书")
    XCTAssertEqual(explore.books.first?.name, "发现脚本书")
    XCTAssertEqual(toc.book.name, "详情脚本书")
    XCTAssertEqual(chapter.title, "脚本章节")
    XCTAssertEqual(content.content.content, "脚本正文")
    XCTAssertEqual(sessionIDs, Set(["http://script.test"]))
  }

  private func scriptDefinition() -> SourceSearchDefinition {
    let listRules = SearchRules(
      list: "@Json:$[*]",
      name: HTMLCSSRule("@js:stageName"),
      author: HTMLCSSRule("@Json:$.author"),
      intro: .optional(nil),
      kind: .optional(nil),
      lastChapter: .optional(nil),
      bookURL: HTMLCSSRule("@Json:$.url", value: .href),
      coverURL: .optional(nil)
    )
    return SourceSearchDefinition(
      sourceURL: "http://script.test",
      sourceName: "脚本书源",
      originOrder: 0,
      runtime: HTMLCSSSourceDefinition(
        searchURLTemplate: "http://script.test/search",
        search: listRules,
        explore: listRules,
        bookInfo: BookInfoRules(
          name: HTMLCSSRule("@js:detailName"),
          author: HTMLCSSRule("@Json:$.author"),
          intro: .optional(nil),
          kind: .optional(nil),
          lastChapter: .optional(nil),
          coverURL: .optional(nil),
          tocURL: HTMLCSSRule("@Json:$.toc", value: .href),
          allowsRename: true
        ),
        toc: TOCRules(
          list: "@Json:$.chapters[*]",
          name: HTMLCSSRule("@js:chapterName"),
          url: HTMLCSSRule("@Json:$.url", value: .href)
        ),
        content: ContentRules(
          content: HTMLCSSRule("@js:chapterContent")
        )
      )
    )
  }
}

private actor ProductScriptRuntime: SourceScriptRuntime {
  private var observedSessionIDs: Set<String> = []

  func evaluate(
    _ request: SourceScriptRequest,
    host: (any SourceScriptHosting)?
  ) async throws -> SourceScriptValue {
    observedSessionIDs.insert(request.sessionID.rawValue)
    switch request.script {
    case "stageName":
      if request.baseURL?.contains("/explore") == true {
        return .string("发现脚本书")
      }
      return .string("搜索脚本书")
    case "detailName":
      return .string("详情脚本书")
    case "chapterName":
      return .string("脚本章节")
    case "chapterContent":
      return .string("脚本正文")
    default:
      throw SourceScriptIssue(code: .executionFailed)
    }
  }

  func sessionIDs() -> Set<String> {
    observedSessionIDs
  }
}

private actor ScriptProductTransport: HTTPTransport {
  func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
    let body: String
    switch URL(string: request.url.absoluteString)?.path {
    case "/search":
      body =
        #"[{"author":"搜索作者","url":"/book"}]"#
    case "/explore":
      body =
        #"[{"author":"发现作者","url":"/book"}]"#
    case "/book":
      body =
        #"{"author":"详情作者","toc":"/toc"}"#
    case "/toc":
      body =
        #"{"chapters":[{"url":"/content"}]}"#
    case "/content":
      body = #"{"raw":"unused"}"#
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
