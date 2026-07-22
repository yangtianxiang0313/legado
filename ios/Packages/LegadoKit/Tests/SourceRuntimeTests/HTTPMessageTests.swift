import Foundation
import LegadoCore
import XCTest

@testable import SourceRuntime

final class HTTPMessageTests: XCTestCase {
  func testHTTPTypesAreSendable() throws {
    func requireSendable<T: Sendable>(_: T) {}

    let url = try HTTPURL("https://example.test/books?q=%E4%B9%A6")
    let body = HTTPBody(Data([0, 255, 128, 10]))
    let request = HTTPRequest(method: .post, url: url, body: body)
    let response = try HTTPResponse(statusCode: 404, effectiveURL: url, body: body)

    requireSendable(HTTPMethod.get)
    requireSendable(url)
    requireSendable(request)
    requireSendable(response)
    requireSendable(HTTPTransportFailure.timeout)
  }

  func testHeadersNormalizeNamesAndCanonicalizeWithoutLosingDuplicates() throws {
    let headers = HTTPHeaders([
      try HTTPHeader(name: "Set-Cookie", value: "a=1"),
      try HTTPHeader(name: "X-Trace", value: "last"),
      try HTTPHeader(name: "set-cookie", value: "b=2"),
      try HTTPHeader(name: "Accept", value: "text/html"),
    ])

    XCTAssertEqual(headers.values(for: "SET-cookie"), ["a=1", "b=2"])
    XCTAssertEqual(headers.canonicalFields.map(\.name), ["accept", "set-cookie", "set-cookie", "x-trace"])
    XCTAssertEqual(headers.canonicalFields.map(\.value), ["text/html", "a=1", "b=2", "last"])
  }

  func testInvalidURLsHeadersTimeoutsAndStatusesAreRejected() throws {
    XCTAssertThrowsError(try HTTPURL("/relative"))
    XCTAssertThrowsError(try HTTPURL("https://example.test/path#fragment"))
    XCTAssertThrowsError(try HTTPHeader(name: "bad name", value: "value"))
    XCTAssertThrowsError(try HTTPHeader(name: "authorization", value: "ok\r\ninjected: yes"))
    XCTAssertThrowsError(try HTTPTimeout(milliseconds: 0))
    XCTAssertThrowsError(
      try HTTPResponse(
        statusCode: 0,
        effectiveURL: HTTPURL("https://example.test"),
        body: HTTPBody(Data())
      )
    )
  }

  func testRawMessagesRoundTripAbsentEmptyAndBinaryBodies() throws {
    let url = try HTTPURL("https://example.test/content")
    let absent = HTTPRequest(method: .get, url: url)
    let empty = HTTPRequest(method: .post, url: url, body: HTTPBody(Data()))
    let binary = try HTTPResponse(
      statusCode: 200,
      effectiveURL: url,
      body: HTTPBody(Data([0, 255, 128, 10]))
    )

    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    XCTAssertEqual(try decoder.decode(HTTPRequest.self, from: encoder.encode(absent)), absent)
    XCTAssertEqual(try decoder.decode(HTTPRequest.self, from: encoder.encode(empty)), empty)
    XCTAssertNotEqual(absent, empty)
    XCTAssertNotEqual(try HTTPEnvelopeCodec.encode(absent), try HTTPEnvelopeCodec.encode(empty))
    XCTAssertEqual(try decoder.decode(HTTPResponse.self, from: encoder.encode(binary)), binary)
  }

  func testEnvelopeEncodingIsStableAndContainsOnlyBodyFingerprint() throws {
    let secret = "secret-body"
    let request = HTTPRequest(
      method: .post,
      url: try HTTPURL("https://example.test/submit"),
      headers: HTTPHeaders([
        try HTTPHeader(name: "X-Z", value: "z"),
        try HTTPHeader(name: "Accept", value: "text/plain"),
      ]),
      body: HTTPBody(Data(secret.utf8)),
      timeout: try HTTPTimeout(milliseconds: 15_000)
    )

    let first = try HTTPEnvelopeCodec.encode(request)
    let second = try HTTPEnvelopeCodec.encode(request)
    let reordered = HTTPRequest(
      method: .post,
      url: try HTTPURL("https://example.test/submit"),
      headers: HTTPHeaders([
        try HTTPHeader(name: "accept", value: "text/plain"),
        try HTTPHeader(name: "x-z", value: "z"),
      ]),
      body: HTTPBody(Data(secret.utf8)),
      timeout: try HTTPTimeout(milliseconds: 15_000)
    )
    let text = try XCTUnwrap(String(data: first, encoding: .utf8))

    XCTAssertEqual(first, second)
    XCTAssertEqual(first, try HTTPEnvelopeCodec.encode(reordered))
    XCTAssertTrue(text.contains(#""method":"POST""#))
    XCTAssertTrue(text.contains(#""timeoutMilliseconds":15000"#))
    XCTAssertTrue(text.contains(#""byteCount":11"#))
    XCTAssertFalse(text.contains(secret))
  }

  func testResponseEnvelopeHasStableStatusHeadersURLAndBinaryBodyDigest() throws {
    let response = try HTTPResponse(
      statusCode: 404,
      effectiveURL: HTTPURL("https://example.test/final"),
      headers: HTTPHeaders([
        try HTTPHeader(name: "Content-Type", value: "application/octet-stream")
      ]),
      body: HTTPBody(Data([0, 255, 128, 10]))
    )

    XCTAssertEqual(
      String(decoding: try HTTPEnvelopeCodec.encode(response), as: UTF8.self),
      #"{"body":{"byteCount":4,"sha256":"6d6f7836f1e146dc0204afb5133dae52fdc05603d8ac2dc793b481b0e0829fd1"},"effectiveURL":"https://example.test/final","headers":[{"name":"content-type","value":"application/octet-stream"}],"statusCode":404}"#
    )
  }
}
