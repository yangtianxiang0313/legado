import Foundation
import XCTest

@testable import SourceRuntime

final class SourceProductRuleIntegrationTests: XCTestCase {
  func testJSONPathImportedSourceFlowsThroughSearchPipeline() async throws {
    let definition = SourceSearchDefinition(
      sourceURL: "http://sourcelab.test",
      sourceName: "JSON 书源",
      originOrder: 9,
      runtime: HTMLCSSSourceDefinition(
        searchURLTemplate:
          "http://sourcelab.test/api/search?q={{key}}",
        search: SearchRules(
          list: "@Json:$.books[*]",
          name: HTMLCSSRule("@Json:$.name"),
          author: HTMLCSSRule("@Json:$.author"),
          intro: HTMLCSSRule("@Json:$.intro"),
          kind: HTMLCSSRule("@Json:$.kind"),
          wordCount: HTMLCSSRule("@Json:$.wordCount"),
          lastChapter: HTMLCSSRule("@Json:$.lastChapter"),
          bookURL: HTMLCSSRule("@Json:$.url", value: .href),
          coverURL: HTMLCSSRule("@Json:$.cover", value: .src)
        ),
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
    let body = """
      {
        "books": [
          {
            "name": "星河纪事",
            "author": "作者：林舟",
            "intro": "来自 JSON API",
            "kind": "科幻",
            "wordCount": 120000,
            "lastChapter": "第二章 回声",
            "url": "/books/star-river",
            "cover": "/covers/star-river.png"
          },
          {
            "name": "重复项",
            "author": "其他作者",
            "url": "/books/star-river"
          }
        ]
      }
      """

    let execution = try await SourceSearchPipeline(
      definition: definition,
      transport: JSONSearchTransport(body: body)
    ).search(SourceSearchInput(keyword: "星河", page: 1))

    XCTAssertEqual(execution.books.count, 1)
    XCTAssertEqual(execution.books[0].name, "星河纪事")
    XCTAssertEqual(execution.books[0].author, "林舟")
    XCTAssertEqual(execution.books[0].intro, "来自 JSON API")
    XCTAssertEqual(execution.books[0].kind, "科幻")
    XCTAssertEqual(execution.books[0].wordCount, "12万字")
    XCTAssertEqual(execution.books[0].lastChapter, "第二章 回声")
    XCTAssertEqual(
      execution.books[0].bookURL,
      "http://sourcelab.test/books/star-river"
    )
    XCTAssertEqual(
      execution.books[0].coverURL,
      "http://sourcelab.test/covers/star-river.png"
    )
  }

  func testExplicitCSSPrefixStillUsesHTMLProductPath() async throws {
    let definition = SourceSearchDefinition(
      sourceURL: "http://sourcelab.test",
      sourceName: "CSS 书源",
      originOrder: 1,
      runtime: HTMLCSSSourceDefinition(
        searchURLTemplate: "http://sourcelab.test/search",
        search: SearchRules(
          list: "@css:.book-item",
          name: HTMLCSSRule("@css:.name@text"),
          author: .optional(nil),
          intro: .optional(nil),
          kind: .optional(nil),
          lastChapter: .optional(nil),
          bookURL: HTMLCSSRule("@css:a@href", value: .href),
          coverURL: .optional(nil, value: .src)
        ),
        bookInfo: BookInfoRules(
          name: HTMLCSSRule(".name"),
          author: .optional(nil),
          intro: .optional(nil),
          kind: .optional(nil),
          lastChapter: .optional(nil),
          coverURL: .optional(nil, value: .src),
          tocURL: HTMLCSSRule("a", value: .href)
        ),
        toc: TOCRules(
          list: ".chapter",
          name: HTMLCSSRule("a"),
          url: HTMLCSSRule("a", value: .href)
        ),
        content: ContentRules(content: HTMLCSSRule("#content"))
      )
    )
    let body = """
      <article class="book-item">
        <span class="name">前缀保留</span>
        <a href="/books/css"></a>
      </article>
      """

    let execution = try await SourceSearchPipeline(
      definition: definition,
      transport: JSONSearchTransport(body: body)
    ).search(SourceSearchInput(keyword: "前缀", page: 1))

    XCTAssertEqual(execution.books.map(\.name), ["前缀保留"])
    XCTAssertEqual(
      execution.books.first?.bookURL,
      "http://sourcelab.test/books/css"
    )
  }

  func testJSONPathImportedSourceFlowsThroughBookInfoPipeline()
    async throws
  {
    let bookURL = URL(
      string: "http://sourcelab.test/books/star-river"
    )!
    let definition = SourceSearchDefinition(
      sourceURL: "http://sourcelab.test",
      sourceName: "JSON 书源",
      originOrder: 9,
      runtime: HTMLCSSSourceDefinition(
        searchURLTemplate: "http://sourcelab.test/api/search",
        search: SearchRules(
          list: "@Json:$.books[*]",
          name: HTMLCSSRule("@Json:$.name"),
          author: HTMLCSSRule("@Json:$.author"),
          intro: .optional(nil),
          kind: .optional(nil),
          lastChapter: .optional(nil),
          bookURL: HTMLCSSRule("@Json:$.url", value: .href),
          coverURL: .optional(nil, value: .src)
        ),
        bookInfo: BookInfoRules(
          name: HTMLCSSRule("@Json:$.name"),
          author: HTMLCSSRule("@Json:$.author"),
          intro: HTMLCSSRule("@Json:$.intro"),
          kind: HTMLCSSRule("@Json:$.kind"),
          wordCount: HTMLCSSRule("@Json:$.wordCount"),
          lastChapter: HTMLCSSRule("@Json:$.lastChapter"),
          coverURL: HTMLCSSRule("@Json:$.cover", value: .src),
          tocURL: HTMLCSSRule("@Json:$.toc", value: .href),
          allowsRename: true
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
    let body = """
      {
        "name": "星河纪事·详情",
        "author": "作者：林舟",
        "intro": "详情接口简介",
        "kind": "科幻,冒险",
        "wordCount": 36000,
        "lastChapter": "第三章 归途",
        "cover": "/covers/detail.png",
        "toc": "/books/star-river/chapters"
      }
      """
    let existing = SourceBook(
      name: "星河纪事",
      author: "旧作者",
      intro: nil,
      kind: nil,
      lastChapter: nil,
      bookURL: bookURL,
      coverURL: nil,
      tocURL: nil
    )

    let execution = try await SourceBookInfoPipeline(
      definition: definition,
      transport: JSONSearchTransport(body: body)
    ).load(book: existing)

    XCTAssertEqual(execution.book.name, "星河纪事·详情")
    XCTAssertEqual(execution.book.author, "林舟")
    XCTAssertEqual(execution.book.intro, "详情接口简介")
    XCTAssertEqual(execution.book.kind, "科幻,冒险")
    XCTAssertEqual(execution.book.wordCount, "3.6万字")
    XCTAssertEqual(execution.book.lastChapter, "第三章 归途")
    XCTAssertEqual(
      execution.book.coverURL?.absoluteString,
      "http://sourcelab.test/covers/detail.png"
    )
    XCTAssertEqual(
      execution.book.tocURL?.absoluteString,
      "http://sourcelab.test/books/star-river/chapters"
    )
  }

  func testJSONPathImportedSourceFlowsThroughTOCPipeline() async throws {
    let definition = SourceSearchDefinition(
      sourceURL: "http://sourcelab.test",
      sourceName: "JSON 书源",
      originOrder: 9,
      runtime: HTMLCSSSourceDefinition(
        searchURLTemplate: "http://sourcelab.test/api/search",
        search: SearchRules(
          list: "@Json:$.books[*]",
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
    let bookURL = URL(
      string: "http://sourcelab.test/books/star-river"
    )!
    let transport = RoutedJSONTransport(
      bodies: [
        "/books/star-river": """
          {"name":"星河纪事","toc":"chapters"}
          """,
        "/books/chapters": """
          {
            "chapters": [
              {"name":"第一章 启航","url":"chapter-1"},
              {"name":"第二章 回声","url":"/content/chapter-2"}
            ]
          }
          """,
      ]
    )

    let execution = try await SourceTOCPipeline(
      definition: definition,
      transport: transport
    ).chapters(
      book: SourceBook(
        name: "星河纪事",
        author: nil,
        intro: nil,
        kind: nil,
        lastChapter: nil,
        bookURL: bookURL,
        coverURL: nil,
        tocURL: nil
      )
    )

    XCTAssertEqual(execution.chapters.map(\.title), [
      "第一章 启航",
      "第二章 回声",
    ])
    XCTAssertEqual(
      execution.chapters.map(\.url.absoluteString),
      [
        "http://sourcelab.test/books/chapter-1",
        "http://sourcelab.test/content/chapter-2",
      ]
    )
  }
}

private actor JSONSearchTransport: HTTPTransport {
  let body: String

  init(body: String) {
    self.body = body
  }

  func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
    try HTTPResponse(
      statusCode: 200,
      effectiveURL: request.url,
      body: HTTPBody(Data(body.utf8))
    )
  }
}

private actor RoutedJSONTransport: HTTPTransport {
  let bodies: [String: String]

  init(bodies: [String: String]) {
    self.bodies = bodies
  }

  func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
    guard
      let path = URL(string: request.url.absoluteString)?.path,
      let body = bodies[path]
    else {
      throw HTTPTransportFailure.connectionFailed
    }
    return try HTTPResponse(
      statusCode: 200,
      effectiveURL: request.url,
      body: HTTPBody(Data(body.utf8))
    )
  }
}
