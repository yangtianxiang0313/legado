import Foundation
import XCTest

@testable import SourceRuntime

final class SourceStringResponseNormalizerTests: XCTestCase {
  func testAddsDeclarationOnlyForCharacterizedXMLResponse() throws {
    let result = try SourceStringResponseNormalizer.normalize(
      response(
        contentType: "application/xml; charset=utf-8",
        body: "<feed><title>星河</title></feed>\n"
      )
    )

    XCTAssertEqual(
      result.body,
      #"<?xml version="1.0"?><feed><title>星河</title></feed>"# + "\n"
    )
    XCTAssertEqual(
      result.finalURL.absoluteString,
      "http://sourcelab.test/xml/example"
    )
  }

  func testPreservesExistingDeclarationIncludingLeadingSpaceAndCase() throws {
    let body = #"  <?XML version="1.0"?><feed/>"# + "\n"
    let result = try SourceStringResponseNormalizer.normalize(
      response(contentType: "text/xml; charset=utf-8", body: body)
    )

    XCTAssertEqual(result.body, body)
  }

  func testDoesNotInferXMLFromBodyWhenContentTypeIsPlainText() throws {
    let body = "<feed><title>文本响应</title></feed>\n"
    let result = try SourceStringResponseNormalizer.normalize(
      response(contentType: "text/plain; charset=utf-8", body: body)
    )

    XCTAssertEqual(result.body, body)
  }

  func testAcceptsAndroidXMLMediaTypePatternButKeepsItCaseSensitive() throws {
    let body = "<feed/>"
    XCTAssertTrue(
      try SourceStringResponseNormalizer.normalize(
        response(contentType: "application/atom+xml; charset=utf-8", body: body)
      ).body.hasPrefix(#"<?xml version="1.0"?>"#)
    )
    XCTAssertEqual(
      try SourceStringResponseNormalizer.normalize(
        response(contentType: "Application/XML", body: body)
      ).body,
      body
    )
  }

  func testRejectsInvalidUTF8WithoutGuessingCharset() throws {
    XCTAssertThrowsError(
      try SourceStringResponseNormalizer.normalize(
        response(
          contentType: "application/xml",
          bytes: Data([0xFF, 0xFE])
        )
      )
    ) { error in
      XCTAssertEqual(error as? SourceStringResponseError, .invalidUTF8)
    }
  }

  func testDeclaredAndDetectedGBKMatchAndroidGolden() throws {
    let declared = try SourceStringResponseNormalizer.normalize(
      response(
        contentType: "text/plain; charset=gbk",
        bytes: try base64("yfnD97HgwuujutDHutMK")
      )
    )
    XCTAssertEqual(declared.body, "声明编码：星河\n")

    let detected = try SourceStringResponseNormalizer.normalize(
      response(
        contentType: "text/html",
        bytes: try base64(
          "PGh0bWw+PGhlYWQ+PG1ldGEgY2hhcnNldD1nYms+PC9oZWFkPjxib2R5Psy9suKx4MLro7rQx7rTPC9ib2R5PjwvaHRtbD4K"
        )
      )
    )
    XCTAssertEqual(
      detected.body,
      "<html><head><meta charset=gbk></head><body>探测编码：星河</body></html>\n"
    )
  }

  func testBOMAndWrongDeclaredCharsetMatchAndroidGolden() throws {
    let bom = try SourceStringResponseNormalizer.normalize(
      response(
        contentType: "text/plain",
        bytes: try base64("77u/Qk9N77ya5pif5rKzCg==")
      )
    )
    XCTAssertEqual(bom.body, "BOM：星河\n")

    let wrong = try SourceStringResponseNormalizer.normalize(
      response(
        contentType: "text/plain; charset=gbk",
        bytes: try base64("6ZSZ6K+v5aOw5piO77ya5pif5rKzCg==")
      )
    )
    XCTAssertEqual(wrong.body, "閿欒澹版槑锛氭槦娌�\n")
  }

  func testGZIPZIPAndMalformedZIPMatchAndroidGolden() throws {
    let gzip = try SourceStringResponseNormalizer.normalize(
      response(
        contentType: "text/plain; charset=utf-8",
        contentEncoding: "gzip",
        bytes: try base64(
          "H4sIAAAAAAAC/3OP8gx4v2fWsxnzn23azAUAlX93HQ4AAAA="
        )
      )
    )
    XCTAssertEqual(gzip.body, "GZIP：星河\n")

    let zip = try SourceStringResponseNormalizer.normalize(
      response(
        contentType: "application/zip",
        bytes: try base64(
          "UEsDBBQAAAAIAAAAIQDhHcznEAAAAA0AAAALAAAAY29udGVudC50eHSL8gx4v2fWsxnzn23azAUAUEsBAhQDFAAAAAgAAAAhAOEdzOcQAAAADQAAAAsAAAAAAAAAAAAAAIABAAAAAGNvbnRlbnQudHh0UEsFBgAAAAABAAEAOQAAADkAAAAAAA=="
        )
      )
    )
    XCTAssertEqual(zip.body, "ZIP：星河\n")

    let malformed = try SourceStringResponseNormalizer.normalize(
      response(
        contentType: "application/zip",
        bytes: try base64("bm90LWEtemlw")
      )
    )
    XCTAssertEqual(malformed.body, "")
  }

  func testRedirectPolicyMatchesAndroidTwentyFollowUpLimit() throws {
    let policy = SourceRedirectPolicy()
    XCTAssertNoThrow(try policy.validate(followUpCount: 20))
    XCTAssertThrowsError(try policy.validate(followUpCount: 21)) { error in
      XCTAssertEqual(error as? SourceStringResponseError, .tooManyRedirects)
    }
  }

  private func response(
    contentType: String,
    body: String
  ) throws -> HTTPResponse {
    try response(contentType: contentType, bytes: Data(body.utf8))
  }

  private func response(
    contentType: String,
    contentEncoding: String? = nil,
    bytes: Data
  ) throws -> HTTPResponse {
    var headers = [
      try HTTPHeader(name: "Content-Type", value: contentType)
    ]
    if let contentEncoding {
      headers.append(
        try HTTPHeader(name: "Content-Encoding", value: contentEncoding)
      )
    }
    return try HTTPResponse(
      statusCode: 200,
      effectiveURL: HTTPURL(
        "http://sourcelab.test/xml/example"
      ),
      headers: HTTPHeaders(headers),
      body: HTTPBody(bytes)
    )
  }

  private func base64(_ value: String) throws -> Data {
    try XCTUnwrap(Data(base64Encoded: value))
  }
}
