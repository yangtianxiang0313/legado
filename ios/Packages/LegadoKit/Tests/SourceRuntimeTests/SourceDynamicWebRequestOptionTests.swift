@testable import SourceRuntime
import XCTest

final class SourceDynamicWebRequestOptionTests: XCTestCase {
  func testURLCompilerPreservesDynamicWebOptions() throws {
    let plan = try SourceRequestCompiler.compile(
      template:
        #"http://source.test/search,{"useWebView":true,"webJs":"document.title"}"#,
      keyword: "book"
    )

    XCTAssertTrue(plan.useWebView)
    XCTAssertEqual(plan.webJS, "document.title")
  }

  func testSourcePreparationDoesNotDropDynamicWebOptions() throws {
    let compiled = try SourceRequestCompiler.compile(
      template:
        #"http://source.test/search,{"useWebView":true,"webJs":"document.body.innerHTML"}"#,
      keyword: "book"
    )
    let definition = SourceSearchDefinition(
      sourceURL: "http://source.test",
      sourceName: "动态书源",
      originOrder: 0,
      runtime: fixtureRuntime()
    )

    let prepared = try definition.prepare(compiled)

    XCTAssertTrue(prepared.useWebView)
    XCTAssertEqual(prepared.webJS, "document.body.innerHTML")
    XCTAssertEqual(
      definition.runtime.content.webJS,
      "window.content()"
    )
    XCTAssertEqual(
      definition.runtime.content.sourceRegex,
      #"/chapter/.*\.js"#
    )
  }

  private func fixtureRuntime() -> HTMLCSSSourceDefinition {
    HTMLCSSSourceDefinition(
      searchURLTemplate: "http://source.test/search",
      search: SearchRules(
        list: "li",
        name: HTMLCSSRule("a"),
        author: .optional(nil),
        intro: .optional(nil),
        kind: .optional(nil),
        lastChapter: .optional(nil),
        bookURL: HTMLCSSRule("a", value: .href),
        coverURL: .optional(nil)
      ),
      bookInfo: BookInfoRules(
        name: HTMLCSSRule("h1"),
        author: .optional(nil),
        intro: .optional(nil),
        kind: .optional(nil),
        lastChapter: .optional(nil),
        coverURL: .optional(nil),
        tocURL: HTMLCSSRule("a", value: .href)
      ),
      toc: TOCRules(
        list: "li",
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
  }
}
