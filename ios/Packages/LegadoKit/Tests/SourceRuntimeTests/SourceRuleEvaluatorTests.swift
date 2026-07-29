import LegadoCore
import XCTest

@testable import SourceRuntime

final class SourceRuleEvaluatorTests: XCTestCase {
  func testHTMLPrefixesAndContentInferenceSelectIndependentBackends() throws {
    let evaluator = SourceRuleEvaluator(
      content:
        "<html><body><section class=\"entry\"><strong>"
        + "Gamma &amp; Delta</strong></section></body></html>"
    )

    let defaultValue = try evaluator.evaluate(".entry strong@text")
    let cssValue = try evaluator.evaluate("@CSS:.entry strong@text")
    let escapedValue = try evaluator.evaluate("@@.entry strong@text")
    let xpathValue = try evaluator.evaluate("@XPath://strong/text()")

    XCTAssertEqual(defaultValue.value, .string("Gamma & Delta"))
    XCTAssertEqual(
      defaultValue.descriptor,
      SourceRuleDescriptor(
        mode: .defaultBackend,
        rule: ".entry strong@text"
      )
    )
    XCTAssertEqual(cssValue.value, .string("Gamma & Delta"))
    XCTAssertEqual(cssValue.descriptor.rule, "@CSS:.entry strong@text")
    XCTAssertEqual(escapedValue.descriptor.rule, ".entry strong@text")
    XCTAssertEqual(xpathValue.value, .string("Gamma & Delta"))
    XCTAssertEqual(xpathValue.descriptor.mode, .xpath)
  }

  func testJSONPathSupportsAutoExplicitIndexAndWildcard() throws {
    let evaluator = SourceRuleEvaluator(
      content:
        #"{"books":[{"title":"One"},{"title":"Two"},{"title":"Three"}]}"#
    )

    XCTAssertEqual(
      try evaluator.evaluate("books[1].title").value,
      .string("Two")
    )
    XCTAssertEqual(
      try evaluator.evaluate("@Json:$.books[0].title").value,
      .string("One")
    )
    XCTAssertEqual(
      try evaluator.evaluate("$.books[*].title").value,
      .array([.string("One"), .string("Two"), .string("Three")])
    )
  }

  func testJavaScriptSuffixAndRegexModeUseCurrentEvaluatorState() throws {
    let scriptEvaluator = SourceRuleEvaluator(content: "base")
    XCTAssertEqual(
      try scriptEvaluator.evaluate(
        "<js>result.toString() + '-value'</js>"
      ),
      SourceRuleEvaluation(
        descriptor: SourceRuleDescriptor(
          mode: .javaScript,
          rule: "result.toString() + '-value'"
        ),
        value: .string("base-value")
      )
    )

    let regexEvaluator = SourceRuleEvaluator(
      content: "chapter-7 chapter-11"
    )
    let activation = try regexEvaluator.evaluate(#":chapter-(\d+)"#)
    let followup = try regexEvaluator.evaluate(#"chapter-(\d+)"#)

    XCTAssertEqual(activation.descriptor.mode, .regex)
    XCTAssertEqual(followup.descriptor.mode, .regex)
    XCTAssertEqual(
      followup.value,
      .array([
        .array([.string("chapter-7"), .string("7")]),
        .array([.string("chapter-11"), .string("11")]),
      ])
    )
  }

  func testParserCacheIsReusedInvalidatedAndForeignContentIsolated() throws {
    let evaluator = SourceRuleEvaluator(
      content: html(value: "current")
    )
    XCTAssertEqual(
      try evaluator.evaluate("@CSS:.value@text").value,
      .string("current")
    )
    let firstIdentity = evaluator.cacheIdentity(for: .defaultBackend)
    XCTAssertEqual(
      try evaluator.evaluate(
        "@CSS:.value@text",
        against: html(value: "foreign")
      ).value,
      .string("foreign")
    )
    XCTAssertEqual(
      evaluator.cacheIdentity(for: .defaultBackend),
      firstIdentity
    )
    XCTAssertEqual(
      try evaluator.evaluate("@CSS:.value@text").value,
      .string("current")
    )

    try evaluator.setContent(html(value: "replacement"))
    XCTAssertEqual(
      try evaluator.evaluate("@CSS:.value@text").value,
      .string("replacement")
    )
    XCTAssertNotEqual(
      evaluator.cacheIdentity(for: .defaultBackend),
      firstIdentity
    )
  }

  func testNativeObjectShortCircuitsAndMissingContentIsTyped() throws {
    let evaluator = SourceRuleEvaluator()
    let native = evaluator.evaluate(
      "title",
      nativeObject: [
        "title": .string("direct"),
        "count": .number(JSONNumber(4)),
      ]
    )

    XCTAssertEqual(native.value, .string("direct"))
    XCTAssertEqual(native.descriptor.mode, .json)
    XCTAssertThrowsError(try evaluator.evaluate("title")) { error in
      XCTAssertEqual(error as? SourceRuleRuntimeError, .missingContent)
    }
    XCTAssertThrowsError(try evaluator.setContent(nil)) { error in
      XCTAssertEqual(error as? SourceRuleRuntimeError, .missingContent)
    }
  }

  func testIndependentEvaluatorsDoNotShareRegexModeOrCaches() throws {
    let first = SourceRuleEvaluator(content: "item-1")
    let second = SourceRuleEvaluator(
      content: "<html><body><p>item-2</p></body></html>"
    )

    XCTAssertEqual(
      try first.evaluate(#":item-(\d+)"#).descriptor.mode,
      .regex
    )
    XCTAssertEqual(
      try second.evaluate("p@text").descriptor.mode,
      .defaultBackend
    )
    XCTAssertNil(first.cacheIdentity(for: .defaultBackend))
    XCTAssertNotNil(second.cacheIdentity(for: .defaultBackend))
  }

  private func html(value: String) -> String {
    "<html><body><p class=\"value\">\(value)</p></body></html>"
  }
}
