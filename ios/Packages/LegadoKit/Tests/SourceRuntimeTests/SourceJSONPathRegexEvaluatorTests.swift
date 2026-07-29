import LegadoCore
import XCTest

@testable import SourceRuntime

final class SourceJSONPathRegexEvaluatorTests: XCTestCase {
  func testJSONPathSupportsObservedDialect() throws {
    let evaluator = try SourceJSONPathEvaluator(
      input: .jsonString(
        #"{"books":[{"title":"A","price":8},{"title":"B","price":12},{"title":"C","price":5}],"nested":{"title":"N"},"odd.key":{"value":"quoted"}}"#
      )
    )

    XCTAssertEqual(
      evaluator.getString("@Json:$.books[?(@.price < 10)].title"),
      "A\nC"
    )
    XCTAssertEqual(
      evaluator.getStringList("@Json:$..title"),
      ["A", "B", "C", "N"]
    )
    XCTAssertEqual(
      evaluator.getStringList("@Json:$.books[0:3:2].title"),
      ["A", "B", "C"]
    )
    XCTAssertEqual(
      evaluator.getString("@Json:$['odd.key'].value"),
      "quoted"
    )
  }

  func testJSONConsumersKeepAndroidNullAndObjectBoundaries() throws {
    let evaluator = try SourceJSONPathEvaluator(
      input: .jsonString(
        #"{"array":["x",2,false,null],"nil":null,"object":{"b":2,"a":1}}"#
      )
    )

    XCTAssertEqual(
      evaluator.getString("@Json:$.array"),
      "x\n2\nfalse\nnull"
    )
    XCTAssertEqual(
      evaluator.getStringList("@Json:$.array"),
      ["x", "2", "false", "null"]
    )
    XCTAssertEqual(
      evaluator.getString("@Json:$.object"),
      "{b=2, a=1}"
    )
    XCTAssertEqual(evaluator.getString("@Json:$.nil"), "")
    XCTAssertEqual(evaluator.getStringList("@Json:$.nil"), [])
    XCTAssertThrowsError(try evaluator.getElement("@Json:$.nil")) {
      XCTAssertEqual($0 as? SourceJSONPathBackendError, .nullElement)
    }
  }

  func testObjectInputUsesAndroidNativeNumberText() throws {
    let evaluator = try SourceJSONPathEvaluator(
      input: .object(
        .object([
          "catalog": .object([
            "items": .array([
              .object([
                "id": .number(JSONNumber(1)),
                "label": .string("one"),
              ])
            ])
          ])
        ])
      )
    )

    XCTAssertEqual(
      evaluator.getString("@Json:$.catalog.items[0]"),
      "{id=1.0, label=one}"
    )
    XCTAssertEqual(
      try evaluator.getElement("@Json:$.catalog.items[0]"),
      JSONValue.object([
        "id": .number(JSONNumber(1)),
        "label": .string("one"),
      ])
    )
  }

  func testCombinationAndInterpolationRemainConsumerSpecific() throws {
    let evaluator = try SourceJSONPathEvaluator(
      input: .jsonString(
        #"{"left":["L1","L2"],"right":["R1","R2","R3"],"meta":{"name":"Alpha","nested":{"value":"Beta"}}}"#
      )
    )

    XCTAssertEqual(
      evaluator.getStringList("@Json:$.left[*]&&$.right[*]"),
      ["L1", "L2", "R1", "R2", "R3"]
    )
    XCTAssertEqual(
      evaluator.getStringList("@Json:$.left[*]%%$.right[*]"),
      ["L1", "R1", "L2", "R2"]
    )
    XCTAssertEqual(
      evaluator.getString("@Json:$.left[*]%%$.right[*]"),
      ""
    )
    XCTAssertEqual(
      evaluator.getString(
        "@Json:prefix-{$.meta.name}-{$.meta.nested.value}"
      ),
      "prefix-Alpha-Beta"
    )
    XCTAssertThrowsError(
      try evaluator.getElement(
        "@Json:prefix-{$.meta.name}-{$.meta.nested.value}"
      )
    ) {
      XCTAssertEqual($0 as? SourceJSONPathBackendError, .pathNotFound)
    }
  }

  func testMissingAndMalformedPathsStayDistinctAtElementBoundary() throws {
    let evaluator = try SourceJSONPathEvaluator(
      input: .jsonString(#"{"present":"value"}"#)
    )

    XCTAssertEqual(evaluator.getString("@Json:$.missing.value"), "")
    XCTAssertEqual(evaluator.getStringList("@Json:$.["), [])
    XCTAssertThrowsError(
      try evaluator.getElement("@Json:$.missing.value")
    ) {
      XCTAssertEqual($0 as? SourceJSONPathBackendError, .pathNotFound)
    }
    XCTAssertThrowsError(try evaluator.getElement("@Json:$.[")) {
      XCTAssertEqual($0 as? SourceJSONPathBackendError, .invalidPath)
    }
  }

  func testRegexCaptureChainOptionalAndZeroWidth() throws {
    let evaluator = SourceRegexEvaluator()
    let items = #"<item id="1">Alpha</item><item id="2">Beta</item>"#

    XCTAssertEqual(
      try evaluator.getElements(
        content: items,
        rule: #":<item id="(\d+)">([^<]+)</item>"#
      ),
      [
        [#"<item id="1">Alpha</item>"#, "1", "Alpha"],
        [#"<item id="2">Beta</item>"#, "2", "Beta"],
      ]
    )
    XCTAssertEqual(
      try evaluator.getElements(
        content: items,
        rule: #":<item id="\d+">[^<]+</item>&&id="(\d+)""#
      ),
      [[#"id="1""#, "1"], [#"id="2""#, "2"]]
    )
    XCTAssertEqual(
      try evaluator.getElements(
        content: "A1 B C3",
        rule: ":([A-Z])(?:(\\d))?"
      ),
      [["A1", "A", "1"], ["B", "B", ""], ["C3", "C", "3"]]
    )
    XCTAssertEqual(
      try evaluator.getElements(content: "A1 C3", rule: ":(?=\\d)"),
      [[""], [""]]
    )
  }

  func testRegexErrorsAreStableSwiftErrors() throws {
    let evaluator = SourceRegexEvaluator()

    XCTAssertThrowsError(
      try evaluator.getElements(
        content: "A1 B 汉字",
        rule: ":(?U)\\b\\w+\\b"
      )
    ) {
      XCTAssertEqual($0 as? SourceRegexBackendError, .invalidPattern)
    }
    XCTAssertThrowsError(
      try evaluator.getElement(content: "A", rule: ":(A)(\\d)?")
    ) {
      XCTAssertEqual($0 as? SourceRegexBackendError, .unmatchedGroup)
    }
  }

  func testReplacementMatchesAllFirstAndJSONListSemantics() {
    let text = SourceRegexReplacementEvaluator(content: "a1 b22 c333")
    XCTAssertEqual(text.getString("##\\d+##X"), "aX bX cX")
    XCTAssertEqual(
      text.getString("##([a-z])(\\d+)##$2-$1"),
      "1-a 22-b 333-c"
    )
    XCTAssertEqual(text.getString("##\\d+##X###"), "X")
    XCTAssertEqual(text.getString("##Z+##X###"), "")

    let json = SourceRegexReplacementEvaluator(
      content: #"{"items":["alpha-1","beta-22","gamma"]}"#
    )
    XCTAssertEqual(
      json.getStringList("@Json:$.items[*]##-\\d+$##"),
      ["alpha", "beta", "gamma"]
    )
    XCTAssertEqual(
      json.getString("@Json:$.items[*]##-\\d+$##"),
      "alpha-1\nbeta-22\ngamma"
    )
  }

  func testInvalidReplacementPatternUsesObservedFallback() {
    let evaluator = SourceRegexReplacementEvaluator(content: "A B [ C")
    XCTAssertEqual(evaluator.getString("##[##X"), "A B X C")
    XCTAssertEqual(evaluator.getString("##[##X###"), "X")
  }
}
