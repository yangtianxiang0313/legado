import Foundation
import LegadoCore
import XCTest

@testable import SourceRuntime

final class SourceRuleConsumerEvaluatorTests: XCTestCase {
  func testJSONListCombinationOperatorsMatchAndroidConsumers() throws {
    let evaluator = SourceRuleConsumerEvaluator(
      content: #"{"left":["A","B","E"],"right":["C","D"]}"#
    )

    XCTAssertEqual(
      try evaluator.getStringList("$.left[*]&&$.right[*]"),
      ["A", "B", "E", "C", "D"]
    )
    XCTAssertEqual(
      try evaluator.getStringList("$.missing[*]||$.right[*]"),
      ["C", "D"]
    )
    XCTAssertEqual(
      try evaluator.getStringList("$.left[*]%%$.right[*]"),
      ["A", "C", "B", "D", "E"]
    )
    XCTAssertEqual(
      try evaluator.getString("$.left[*]%%$.right[*]"),
      ""
    )
  }

  func testScalarAndEmptyConsumersRemainDistinct() throws {
    let evaluator = SourceRuleConsumerEvaluator(
      content:
        #"{"number":12,"boolean":true,"null":null,"string":"plain"}"#
    )

    XCTAssertEqual(try evaluator.getString("$.number"), "12")
    XCTAssertEqual(try evaluator.getStringList("$.boolean"), ["true"])
    XCTAssertEqual(try evaluator.getString("$.null"), "")
    XCTAssertEqual(try evaluator.getStringList("$.null"), [])
    XCTAssertEqual(try evaluator.getString(nil), "")
    XCTAssertNil(try evaluator.getStringList(nil))
    XCTAssertNil(try evaluator.getElement(""))
    XCTAssertEqual(try evaluator.getElements(""), [])
  }

  func testSequentialCSSAndJavaScriptUseConsumerSpecificIntermediate() throws {
    let evaluator = SourceRuleConsumerEvaluator(
      content:
        "<html><body><span class=\"item\">Alpha</span>"
        + "<span class=\"item\">Beta</span></body></html>"
    )

    XCTAssertEqual(
      try evaluator.getString(
        "@CSS:.item@text<js>result.toString() + '-tail'</js>"
      ),
      "Alpha\nBeta-tail"
    )
    XCTAssertEqual(
      try evaluator.getStringList(
        "@CSS:.item@text<js>"
          + "result.get(0).toString() + '|' + "
          + "result.get(1).toString()</js>"
      ),
      ["Alpha|Beta"]
    )
  }

  func testURLListPreservesTrailingEmptyAndFirstOccurrence() throws {
    let evaluator = SourceRuleConsumerEvaluator(content: "seed")
    let redirect = try XCTUnwrap(
      URL(string: "https://example.test/base/chapter/index.html")
    )

    XCTAssertEqual(
      try evaluator.getStringList(
        #"@js:'/a\n/a\n../b\n'"#,
        isURL: true,
        redirectURL: redirect
      ),
      [
        "https://example.test/a",
        "https://example.test/base/b",
        "https://example.test/base/chapter/index.html",
      ]
    )
  }

  func testElementShapesAndScriptFailureStayTyped() throws {
    let evaluator = SourceRuleConsumerEvaluator(
      content:
        #"{"objects":[{"name":"A"},{"name":"B"}],"scalar":7}"#
    )

    XCTAssertEqual(
      try evaluator.getElement("@Json:$.objects[0]"),
      .object(["name": .string("A")])
    )
    XCTAssertEqual(
      try evaluator.getElements("@Json:$.objects[*]"),
      [
        .object(["name": .string("A")]),
        .object(["name": .string("B")]),
      ]
    )
    XCTAssertEqual(
      try evaluator.getElement("@Json:$.scalar"),
      .number(JSONNumber(7))
    )
    XCTAssertThrowsError(
      try evaluator.getString("@js:throw new Error('boom')")
    ) { error in
      XCTAssertEqual(error as? SourceRuleRuntimeError, .scriptFailure)
    }
  }
}
