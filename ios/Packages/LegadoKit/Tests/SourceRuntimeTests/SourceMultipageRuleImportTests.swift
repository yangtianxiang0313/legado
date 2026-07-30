import XCTest

@testable import SourceRuntime

final class SourceMultipageRuleImportTests: XCTestCase {
  func testDefinitionRetainsAndroidPaginationRules() {
    let toc = TOCRules(
      list: "@Json:$.chapters[*]",
      name: HTMLCSSRule("@Json:$.name"),
      url: HTMLCSSRule("@Json:$.url", value: .href),
      nextTocURL: HTMLCSSRule(
        "@Json:$.next",
        value: .href
      )
    )
    let content = ContentRules(
      content: HTMLCSSRule("@Json:$.content"),
      nextContentURL: HTMLCSSRule(
        "@Json:$.next",
        value: .href
      )
    )

    XCTAssertEqual(
      toc.nextTocURL?.selector,
      "@Json:$.next"
    )
    XCTAssertEqual(
      content.nextContentURL?.selector,
      "@Json:$.next"
    )
  }
}
