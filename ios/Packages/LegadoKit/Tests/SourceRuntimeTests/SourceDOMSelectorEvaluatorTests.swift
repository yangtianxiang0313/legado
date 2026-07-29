import Foundation
import XCTest

@testable import SourceRuntime

final class SourceDOMSelectorEvaluatorTests: XCTestCase {
  func testCSSDerivationsAndPrettyHTMLMatchFrozenAndroidSurface() throws {
    let evaluator = SourceDOMSelectorEvaluator(
      content:
        "<html><body><article class=\"card\" data-code=\"A1\"> leading "
        + "<h1>Alpha &amp; Beta</h1><div class=\"body\">First <b>bold</b>"
        + "<script>drop()</script><style>.x{}</style> tail</div>"
        + "<a class=\"link\" href=\"../book/1?x=1&amp;y=2\">Read</a>"
        + "</article></body></html>"
    )

    XCTAssertEqual(
      try evaluator.getString("@CSS:.card@text"),
      "leading Alpha & Beta First bold tail Read"
    )
    XCTAssertEqual(try evaluator.getString("@CSS:.card@ownText"), "leading")
    XCTAssertEqual(
      try evaluator.getString("@CSS:.body@textNodes"),
      "First\ntail"
    )
    XCTAssertEqual(
      try evaluator.getString("@CSS:.body@html"),
      "<div class=\"body\">\n First <b>bold</b> tail\n</div>"
    )
    XCTAssertEqual(
      try evaluator.getString("@CSS:.body@all"),
      "<div class=\"body\">\n First <b>bold</b>\n"
        + " <script>drop()</script>\n <style>.x{}</style> tail\n</div>"
    )
    XCTAssertEqual(try evaluator.getString("@CSS:.card@data-code"), "A1")
    XCTAssertEqual(
      try evaluator.getString("@CSS:.link@href"),
      "../book/1?x=1&y=2"
    )
  }

  func testCSSIndexCombinationAndURLSemanticsMatchFrozenAndroidSurface()
    throws
  {
    let indexing = SourceDOMSelectorEvaluator(
      content:
        "<html><body><ul id=\"items\"><li>zero</li><li>one</li>"
        + "<li>two</li><li>three</li></ul></body></html>"
    )
    XCTAssertEqual(
      try indexing.getStringList("#items@children.1@text"),
      ["one"]
    )
    XCTAssertEqual(
      try indexing.getStringList("#items@tag.li[-1,0]@text"),
      ["three", "zero"]
    )
    XCTAssertEqual(
      try indexing.getStringList("#items@tag.li[0:3:2]@text"),
      ["zero", "two"]
    )
    XCTAssertEqual(
      try indexing.getStringList("#items@tag.li[!1,3]@text"),
      ["zero", "two"]
    )
    XCTAssertEqual(
      try indexing.getStringList("#items@tag.li[-1:0]@text"),
      ["three", "two", "one", "zero"]
    )

    let combinations = SourceDOMSelectorEvaluator(
      content:
        "<html><body><ul><li class=\"left\">L1</li>"
        + "<li class=\"right\">R1</li><li class=\"left\">L2</li>"
        + "<li class=\"right\">R2</li></ul></body></html>"
    )
    XCTAssertEqual(
      try combinations.getStringList(
        "@CSS:li.left@text&&li.right@text"
      ),
      ["L1", "L2", "R1", "R2"]
    )
    XCTAssertEqual(
      try combinations.getStringList(
        "@CSS:li.missing@text||li.right@text"
      ),
      ["R1", "R2"]
    )
    XCTAssertEqual(
      try combinations.getStringList(
        "@CSS:li.left@text%%li.right@text"
      ),
      ["L1", "R1", "L2", "R2"]
    )

    let urls = SourceDOMSelectorEvaluator(
      content:
        "<html><body><a href=\"../book/1\">one</a>"
        + "<a href=\"../book/1\">duplicate</a>"
        + "<a href=\"/book/2\">two</a></body></html>"
    )
    let base = try XCTUnwrap(
      URL(string: "https://reader.example.test/catalog/list/index.html")
    )
    XCTAssertEqual(
      try urls.getStringList("@CSS:a@href", isURL: true, redirectURL: base),
      [
        "https://reader.example.test/catalog/book/1",
        "https://reader.example.test/book/2",
      ]
    )
    XCTAssertEqual(
      try urls.getString(
        "@CSS:a.missing@href",
        isURL: true,
        redirectURL: base
      ),
      base.absoluteString
    )
    XCTAssertEqual(
      try urls.getStringList(
        "@CSS:a.missing@href",
        isURL: true,
        redirectURL: base
      ),
      []
    )
  }

  func testXPathNodesFragmentsAndFailureBoundaryMatchFrozenAndroidSurface()
    throws
  {
    let evaluator = SourceDOMSelectorEvaluator(
      content:
        "<html><body><ul><li data-id=\"1\">Alpha <b>A</b></li>"
        + "<li data-id=\"2\">Beta</li></ul></body></html>"
    )
    XCTAssertEqual(
      try evaluator.getStringList("@XPath://li/text()"),
      ["Alpha", "Beta"]
    )
    XCTAssertEqual(
      try evaluator.getStringList("@XPath://li/@data-id"),
      ["1", "2"]
    )
    XCTAssertEqual(
      try evaluator.getElements("@XPath://li"),
      [
        SourceDOMNodeProjection(
          kind: .xpathElement,
          asString: "<li data-id=\"1\">Alpha <b>A</b></li>",
          rendered: "<li data-id=\"1\">Alpha <b>A</b></li>",
          tag: "li"
        ),
        SourceDOMNodeProjection(
          kind: .xpathElement,
          asString: "<li data-id=\"2\">Beta</li>",
          rendered: "<li data-id=\"2\">Beta</li>",
          tag: "li"
        ),
      ]
    )
    XCTAssertEqual(
      try evaluator.getElements("@XPath://li/text()").map(\.tag),
      ["JX_TEXT", "JX_TEXT"]
    )
    XCTAssertEqual(
      try evaluator.getElements("@XPath://li/@data-id").map(\.kind),
      [.xpathValue, .xpathValue]
    )

    XCTAssertThrowsError(
      try evaluator.getString("@XPath:string(//li)")
    ) {
      XCTAssertEqual(
        $0 as? SourceDOMSelectorError,
        .malformedXPath("string(//li)")
      )
    }
    XCTAssertThrowsError(try evaluator.getElements("@CSS:div[")) {
      XCTAssertEqual(
        $0 as? SourceDOMSelectorError,
        .malformedCSS("div[")
      )
    }
  }

  func testXPathToleratesTableAndOptionalListItemFragments() throws {
    XCTAssertEqual(
      try SourceDOMSelectorEvaluator(content: "<td>Cell</td>")
        .getStringList("@XPath://td/text()"),
      ["Cell"]
    )
    XCTAssertEqual(
      try SourceDOMSelectorEvaluator(
        content: "<tr><td>Row A</td><td>Row B</td></tr>"
      ).getStringList("@XPath://td/text()"),
      ["Row A", "Row B"]
    )
    XCTAssertEqual(
      try SourceDOMSelectorEvaluator(content: "<ul><li>One<li>Two</ul>")
        .getStringList("@XPath://li/text()"),
      ["One", "Two"]
    )
  }
}
