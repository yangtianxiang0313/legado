import XCTest

@testable import SourceRuntime

final class SourceFieldEncodingTests: XCTestCase {
  func testUTF8PreservedEncodingDuplicateAndEmptyValuesMatchAndroid() throws {
    let fields = try SourceFieldCompiler.compile(
      "plain=星河&encoded=%E6%98%9F%E6%B2%B3&dup=first&dup=second&empty=&flag"
    )

    XCTAssertEqual(
      fields,
      [
        HTTPFormField(key: "plain", value: "%E6%98%9F%E6%B2%B3"),
        HTTPFormField(key: "encoded", value: "%E6%98%9F%E6%B2%B3"),
        HTTPFormField(key: "dup", value: "second"),
        HTTPFormField(key: "empty", value: ""),
        HTTPFormField(key: "flag", value: ""),
      ]
    )
  }

  func testGBKEncodingMatchesAndroid() throws {
    XCTAssertEqual(
      try SourceFieldCompiler.compile("word=星河&space=a b", charset: "GBK"),
      [
        HTTPFormField(key: "word", value: "%D0%C7%BA%D3"),
        HTTPFormField(key: "space", value: "a+b"),
      ]
    )
  }

  func testEscapeEncodingMatchesAndroid() throws {
    XCTAssertEqual(
      try SourceFieldCompiler.compile("word=星 河+%", charset: "escape"),
      [
        HTTPFormField(key: "word", value: "%u661f%20%u6cb3%2b%25")
      ]
    )
  }

  func testUnsupportedCharsetFailsClosed() {
    XCTAssertThrowsError(
      try SourceFieldCompiler.compile("word=星河", charset: "not-a-charset")
    ) { error in
      XCTAssertEqual(
        error as? SourceFieldEncodingError,
        .unsupportedCharset("not-a-charset")
      )
    }
  }

  func testGETRequestCompilerUsesSameOrderedFieldSemantics() throws {
    let plan = try SourceRequestCompiler.compile(
      template:
        "http://sourcelab.test/fields?q={{key}}&dup=first&dup=second&flag",
      keyword: "星河"
    )

    XCTAssertEqual(
      plan.request.url.absoluteString,
      "http://sourcelab.test/fields?"
        + "q=%E6%98%9F%E6%B2%B3&dup=second&flag="
    )
    XCTAssertEqual(
      plan.formFields,
      [
        HTTPFormField(key: "q", value: "%E6%98%9F%E6%B2%B3"),
        HTTPFormField(key: "dup", value: "second"),
        HTTPFormField(key: "flag", value: ""),
      ]
    )
  }
}
