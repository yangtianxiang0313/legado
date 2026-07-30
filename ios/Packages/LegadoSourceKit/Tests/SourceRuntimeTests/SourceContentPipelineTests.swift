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
}

private actor ContentTransport: HTTPTransport {
  let html: String

  init(html: String) {
    self.html = html
  }

  func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
    try HTTPResponse(
      statusCode: 200,
      effectiveURL: request.url,
      body: HTTPBody(Data(html.utf8))
    )
  }
}

private func contentDefinition() -> SourceSearchDefinition {
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
        content: HTMLCSSRule("#content", value: .html)
      )
    )
  )
}
