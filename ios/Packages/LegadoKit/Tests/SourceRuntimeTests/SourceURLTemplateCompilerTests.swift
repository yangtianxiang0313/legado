import XCTest

@testable import SourceRuntime

final class SourceURLTemplateCompilerTests: XCTestCase {
  func testInlineJSKeyPageOptionMatchesAndroid() throws {
    let output = try SourceURLTemplateCompiler.compile(
      SourceURLTemplateInput(
        template:
          #"/template/{{1 + 1}}/{{key}}/<one,two,last>,{"method":"POST","body":"term={{key}}","retry":2}"#,
        key: "星河",
        page: 2,
        baseURL: "http://sourcelab.test"
      )
    )

    XCTAssertEqual(
      output.ruleURL,
      #"/template/2/星河/two,{"method":"POST","body":"term=星河","retry":2}"#
    )
    XCTAssertEqual(
      output.logicalURL,
      "http://sourcelab.test/template/2/星河/two"
    )
    XCTAssertEqual(output.plan.request.url.absoluteString, output.logicalURL)
    XCTAssertEqual(output.plan.request.method, .post)
    XCTAssertEqual(output.plan.body, "term=%E6%98%9F%E6%B2%B3")
    XCTAssertEqual(output.plan.retry, 2)
  }

  func testScriptBlockAndResultSuffixMatchAndroid() throws {
    let output = try SourceURLTemplateCompiler.compile(
      SourceURLTemplateInput(
        template: "<js>'/template/block/' + key</js>@result/tail",
        key: "河流",
        page: 1,
        baseURL: "http://sourcelab.test"
      )
    )

    XCTAssertEqual(output.ruleURL, "/template/block/河流/tail")
    XCTAssertEqual(
      output.logicalURL,
      "http://sourcelab.test/template/block/河流/tail"
    )
  }

  func testNullRelativeURLAndLastPageFallbackMatchAndroid() throws {
    let output = try SourceURLTemplateCompiler.compile(
      SourceURLTemplateInput(
        template: "../template/{{null}}/<first,second,last>",
        page: 5,
        baseURL: "http://sourcelab.test/library/catalog/index.html"
      )
    )

    XCTAssertEqual(output.ruleURL, "../template//last")
    XCTAssertEqual(
      output.plan.request.url.absoluteString,
      "http://sourcelab.test/library/template//last"
    )
  }

  func testNestedFunctionExpressionMatchesAndroid() throws {
    let output = try SourceURLTemplateCompiler.compile(
      SourceURLTemplateInput(
        template: "/template/{{(function(){ return 3; })()}}/<first,second>",
        page: 2,
        baseURL: "http://sourcelab.test"
      )
    )

    XCTAssertEqual(output.ruleURL, "/template/3/second")
    XCTAssertEqual(
      output.plan.request.url.absoluteString,
      "http://sourcelab.test/template/3/second"
    )
  }

  func testUnsupportedScriptFailsClosed() {
    XCTAssertThrowsError(
      try SourceURLTemplateCompiler.compile(
        SourceURLTemplateInput(
          template: "/template/{{java.get('secret')}}",
          baseURL: "http://sourcelab.test"
        )
      )
    )
  }
}
