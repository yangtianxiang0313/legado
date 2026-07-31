import Foundation
import XCTest

@testable import SourceRuntime

final class SourceContentPipelineTests: XCTestCase {
  func testChapterResponseProducesNormalizedReaderContent() async throws {
    let transport = ContentTransport(
      html: """
      <html><body><div id="content">
        <p>第一段。</p><p>第二段。</p>
      </div></body></html>
      """
    )
    let result = try await SourceContentPipeline(
      definition: contentDefinition(),
      transport: transport
    ).content(chapterURL: "http://sourcelab.test/chapter-1")

    XCTAssertEqual(
      result.content.content,
      "　　第一段。\n　　第二段。"
    )
    XCTAssertEqual(
      result.request.url.absoluteString,
      "http://sourcelab.test/chapter-1"
    )
  }

  func testContentReplaceRegexRunsAfterPagesAreMerged() async throws {
    let transport = ContentTransport(responses: [
      "http://sourcelab.test/chapter-1": """
        <html><body><div id="content"><p>  第一段  </p></div>
        <a class="next" href="/chapter-2">下一页</a></body></html>
        """,
      "http://sourcelab.test/chapter-2": """
        <html><body><div id="content"><p>  第二段  </p></div></body></html>
        """,
    ])
    let definition = contentDefinition(
      nextContentURL: HTMLCSSRule("a.next", value: .href),
      replaceRegex: "##第一段\\n第二段##合并段"
    )
    let result = try await SourceContentPipeline(
      definition: definition,
      transport: transport
    ).content(chapterURL: "http://sourcelab.test/chapter-1")

    XCTAssertEqual(result.content.content, "　　合并段")
  }
}

private actor ContentTransport: HTTPTransport {
  let responses: [String: String]

  init(html: String) {
    self.responses = ["http://sourcelab.test/chapter-1": html]
  }

  init(responses: [String: String]) {
    self.responses = responses
  }

  func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
    guard let html = responses[request.url.absoluteString] else {
      throw URLError(.resourceUnavailable)
    }
    return try HTTPResponse(
      statusCode: 200,
      effectiveURL: request.url,
      body: HTTPBody(Data(html.utf8))
    )
  }
}

private func contentDefinition(
  nextContentURL: HTMLCSSRule? = nil,
  replaceRegex: String? = nil
) -> SourceSearchDefinition {
  SourceSearchDefinition(
    sourceURL: "http://sourcelab.test",
    sourceName: "测试源",
    originOrder: 0,
    runtime: HTMLCSSSourceDefinition(
      searchURLTemplate: "http://sourcelab.test/search?q={{key}}",
      search: SearchRules(
        list: ".book",
        name: HTMLCSSRule(".name"),
        author: HTMLCSSRule(".author"),
        intro: HTMLCSSRule(".intro"),
        kind: HTMLCSSRule(".kind"),
        lastChapter: HTMLCSSRule(".last"),
        bookURL: HTMLCSSRule("a", value: .href),
        coverURL: HTMLCSSRule("img", value: .src)
      ),
      bookInfo: BookInfoRules(
        name: HTMLCSSRule(".name"),
        author: HTMLCSSRule(".author"),
        intro: HTMLCSSRule(".intro"),
        kind: HTMLCSSRule(".kind"),
        lastChapter: HTMLCSSRule(".last"),
        coverURL: HTMLCSSRule("img", value: .src),
        tocURL: HTMLCSSRule(".toc", value: .href)
      ),
      toc: TOCRules(
        list: ".chapter",
        name: HTMLCSSRule("a"),
        url: HTMLCSSRule("a", value: .href)
      ),
      content: ContentRules(
        content: HTMLCSSRule("#content", value: .html),
        nextContentURL: nextContentURL,
        webJS: nil,
        sourceRegex: nil,
        replaceRegex: replaceRegex
      )
    )
  )
}
