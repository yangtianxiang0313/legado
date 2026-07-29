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

  private func response(
    contentType: String,
    body: String
  ) throws -> HTTPResponse {
    try response(contentType: contentType, bytes: Data(body.utf8))
  }

  private func response(
    contentType: String,
    bytes: Data
  ) throws -> HTTPResponse {
    try HTTPResponse(
      statusCode: 200,
      effectiveURL: HTTPURL(
        "http://sourcelab.test/xml/example"
      ),
      headers: HTTPHeaders([
        try HTTPHeader(name: "Content-Type", value: contentType)
      ]),
      body: HTTPBody(bytes)
    )
  }
}
