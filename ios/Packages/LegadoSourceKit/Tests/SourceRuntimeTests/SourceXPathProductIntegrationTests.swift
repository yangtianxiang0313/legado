import LegadoCore
import RuleRuntime
@testable import SourceRuntime
import XCTest

final class SourceXPathProductIntegrationTests: XCTestCase {
  private let html = """
    <html><body><ul>
      <li class="picked">Alpha</li><li>Beta</li>
    </ul><a href="/book/1">Book</a></body></html>
    """

  func testUnifiedConsumerDispatchesPrefixedAndLeadingXPath() throws {
    let evaluator = SourceRuleConsumerEvaluator(
      content: html,
      htmlSelectorBackend: ProductDOMBackend()
    )

    XCTAssertEqual(
      try evaluator.getString("@XPath://li[@class='picked'][1]/text()"),
      "Alpha"
    )
    XCTAssertEqual(
      try evaluator.getStringList("//li/text()"),
      ["Alpha", "Beta"]
    )
    XCTAssertEqual(
      try evaluator.getElements("@XPath://a/@href"),
      [.string("/book/1")]
    )
    XCTAssertEqual(
      try evaluator.getElement("@XPath://li"),
      .string("<li class=\"picked\">Alpha</li>")
    )
  }

  func testProjectionKindsRemainLibraryNeutral() throws {
    let evaluator = SourceDOMSelectorEvaluator(
      content: html,
      htmlSelectorBackend: ProductDOMBackend()
    )

    XCTAssertEqual(
      try evaluator.getElements("@XPath://li/text()").map(\.kind),
      [.xpathElement, .xpathElement]
    )
    XCTAssertEqual(
      try evaluator.getElements("@XPath://li/text()").map(\.tag),
      ["JX_TEXT", "JX_TEXT"]
    )
    XCTAssertEqual(
      try evaluator.getElements("@XPath://a/@href").map(\.kind),
      [.xpathValue]
    )
  }

  func testAndroidPublishedXPathFailureAndNamespaceBoundaries() throws {
    let evaluator = SourceDOMSelectorEvaluator(
      content: html,
      htmlSelectorBackend: ProductDOMBackend()
    )

    for expression in [
      "string(//li)",
      "normalize-space(string(//li))",
      "count(//li)",
      "namespace-uri(//li)",
      "//*[local-name()='li']/text()",
      "//*[",
    ] {
      XCTAssertThrowsError(try evaluator.getString("@XPath:\(expression)")) {
        XCTAssertEqual(
          $0 as? SourceDOMSelectorError,
          .malformedXPath(expression)
        )
      }
    }

    XCTAssertEqual(
      try evaluator.getStringList("@XPath://b:title/text()"),
      []
    )
    XCTAssertEqual(
      try evaluator.getStringList(
        "@XPath://a[@href='https://example.com']/@href"
      ),
      ["https://example.com"]
    )
    XCTAssertEqual(
      try evaluator.getElements("@XPath://missing"),
      []
    )
  }
}

private struct ProductDOMBackend: HTMLSelectorBackend, XPathSelectorBackend {
  func select(
    html: String,
    selector: String
  ) throws -> [HTMLSelectionProjection] {
    []
  }

  func select(
    html: String,
    expression: String
  ) throws -> [XPathSelectionProjection] {
    switch expression {
    case "//li[@class='picked'][1]/text()":
      return [text("Alpha")]
    case "//li/text()":
      return [text("Alpha"), text("Beta")]
    case "//a/@href":
      return [attribute("/book/1")]
    case "//a[@href='https://example.com']/@href":
      return [attribute("https://example.com")]
    case "//li":
      return [element("<li class=\"picked\">Alpha</li>", tag: "li")]
    default:
      return []
    }
  }

  private func text(_ value: String) -> XPathSelectionProjection {
    XPathSelectionProjection(
      kind: .text,
      stringValue: value,
      rendered: value,
      tag: "JX_TEXT"
    )
  }

  private func attribute(_ value: String) -> XPathSelectionProjection {
    XPathSelectionProjection(
      kind: .attribute,
      stringValue: value,
      rendered: value,
      tag: nil
    )
  }

  private func element(
    _ rendered: String,
    tag: String
  ) -> XPathSelectionProjection {
    XPathSelectionProjection(
      kind: .element,
      stringValue: rendered,
      rendered: rendered,
      tag: tag
    )
  }
}
