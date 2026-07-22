import Foundation
import XCTest

@testable import TestSupport

final class FixtureTransportTests: XCTestCase {
  func testDeclaredRequestReturnsRawOfflineResponse() async throws {
    let fixture = try FixtureLoader.load(from: FixtureTestPaths.offlineFixture)
    let transport = FixtureTransport(fixture: fixture)

    let response = try await transport.execute(fixture.request)

    XCTAssertEqual(response.statusCode, 200)
    XCTAssertEqual(response.effectiveURL, fixture.request.url)
    XCTAssertEqual(String(decoding: response.body.bytes, as: UTF8.self), #"{"books":[]}"# + "\n")
    let requestCount = await transport.recordedRequestPlan().count
    XCTAssertEqual(requestCount, 1)
  }

  func testUndeclaredRequestFailsStablyWithoutFallback() async throws {
    let fixture = try FixtureLoader.load(from: FixtureTestPaths.offlineFixture)
    let transport = FixtureTransport(fixture: fixture)
    let undeclared = try fixture.request(
      replacingURL: "https://outside.test/search?q=%E6%98%9F%E6%B2%B3"
    )

    for _ in 0..<2 {
      do {
        _ = try await transport.execute(undeclared)
        XCTFail("Expected undeclared request failure")
      } catch let error as FixtureTransportError {
        XCTAssertEqual(error, .unexpectedRequest)
      }
    }
    let requestCount = await transport.recordedRequestPlan().count
    XCTAssertEqual(requestCount, 2)
  }

  func testSourceLabDeclaredResponsesUseLogicalOriginIncludingDeclared404() async throws {
    let fixture = try FixtureLoader.load(from: FixtureTestPaths.sourceLabFixture)
    let transport = FixtureTransport(fixture: fixture)
    let search = try XCTUnwrap(fixture.requestCases.first { $0.id == "search-hit" })
    let missing = try XCTUnwrap(fixture.requestCases.first { $0.id == "book-not-found" })

    let searchResponse = try await transport.execute(search.request)
    let missingResponse = try await transport.execute(missing.request)

    XCTAssertEqual(searchResponse.statusCode, 200)
    XCTAssertEqual(searchResponse.effectiveURL, search.request.url)
    XCTAssertEqual(missingResponse.statusCode, 404)
    XCTAssertEqual(missingResponse.effectiveURL, missing.request.url)
    XCTAssertTrue(String(decoding: searchResponse.body.bytes, as: UTF8.self).contains("星河纪事"))
  }

  func testSourceLabRejectsAuthorityTargetQueryAndUndeclaredRouteStably() async throws {
    let fixture = try FixtureLoader.load(from: FixtureTestPaths.sourceLabFixture)
    let transport = FixtureTransport(fixture: fixture)
    let cases: [(String, FixtureTransportError)] = [
      ("https://outside.test/search.html?q=x", .externalAuthority),
      ("http://sourcelab.test:80/search.html?q=x", .externalAuthority),
      ("http://sourcelab.test//outside", .invalidTarget),
    ]

    for (url, expected) in cases {
      do {
        _ = try await transport.execute(fixture.request(replacingURL: url))
        XCTFail("Expected SourceLab guard failure for \(url)")
      } catch let error as FixtureTransportError {
        XCTAssertEqual(error, expected)
      }
    }
    let rejectedRequestCount = await transport.recordedRequestPlan().count
    XCTAssertEqual(rejectedRequestCount, 0)

    let consumedCases: [(String, FixtureTransportError)] = [
      ("http://sourcelab.test/undeclared", .unexpectedRequest),
      ("http://sourcelab.test/search.html?q", .invalidQuery),
      ("http://sourcelab.test/search.html?q=1&%71=2", .duplicateQuery),
    ]
    for (url, expected) in consumedCases {
      do {
        _ = try await transport.execute(fixture.request(replacingURL: url))
        XCTFail("Expected SourceLab guard failure for \(url)")
      } catch let error as FixtureTransportError {
        XCTAssertEqual(error, expected)
      }
    }
    let consumedRequestCount = await transport.recordedRequestPlan().count
    XCTAssertEqual(consumedRequestCount, 3)
  }

  func testSourceLabBodyAndRequestBudgetsFailClosed() async throws {
    let fixture = try FixtureLoader.load(from: FixtureTestPaths.sourceLabFixture)
    let bodyTransport = FixtureTransport(fixture: fixture)
    let oversized = fixture.request(
      replacingBody: Data(repeating: 0, count: fixture.definition.limits.maxRequestBodyBytes + 1)
    )

    do {
      _ = try await bodyTransport.execute(oversized)
      XCTFail("Expected oversized body failure")
    } catch let error as FixtureTransportError {
      XCTAssertEqual(error, .requestBodyTooLarge)
    }
    let bodyRequestCount = await bodyTransport.recordedRequestPlan().count
    XCTAssertEqual(bodyRequestCount, 1)

    let requestTransport = FixtureTransport(fixture: fixture)
    for _ in 0..<fixture.definition.limits.maxRequests {
      _ = try await requestTransport.execute(fixture.request)
    }
    do {
      _ = try await requestTransport.execute(fixture.request)
      XCTFail("Expected request budget failure")
    } catch let error as FixtureTransportError {
      XCTAssertEqual(error, .requestLimitExceeded)
    }
    let recordedRequestCount = await requestTransport.recordedRequestPlan().count
    XCTAssertEqual(recordedRequestCount, fixture.definition.limits.maxRequests)
  }

  func testSourceLabQueryMatchingFollowsFormSemantics() throws {
    let fixture = try FixtureLoader.load(from: FixtureTestPaths.sourceLabFixture)
    let origin = fixture.logicalOrigin
    let route = try FixtureRequestTarget(
      method: .get,
      origin: origin,
      path: "/search.html",
      query: ["a": "hello world", "b": "2"]
    )
    let reordered = try FixtureRequestTarget(
      method: .get,
      sourceLabURL: fixture.request(
        replacingURL: "http://sourcelab.test/search.html?b=2&a=hello+world"
      ).url,
      origin: origin
    )
    let percentEncoded = try FixtureRequestTarget(
      method: .get,
      sourceLabURL: fixture.request(
        replacingURL: "http://sourcelab.test/search.html?a=hello%20world&b=2"
      ).url,
      origin: origin
    )
    let composed = try FixtureRequestTarget(
      method: .get,
      origin: origin,
      path: "/search.html",
      query: ["q": "é"]
    )
    let decomposed = try FixtureRequestTarget(
      method: .get,
      sourceLabURL: fixture.request(
        replacingURL: "http://sourcelab.test/search.html?q=e%CC%81"
      ).url,
      origin: origin
    )
    let invalidPercentEscape = try FixtureRequestTarget(
      method: .get,
      sourceLabURL: fixture.request(
        replacingURL: "http://sourcelab.test/search.html?q=%ZZ"
      ).url,
      origin: origin
    )

    XCTAssertEqual(route, reordered)
    XCTAssertEqual(route, percentEncoded)
    XCTAssertNotEqual(composed, decomposed)
    XCTAssertEqual(invalidPercentEscape.query.first?.value, "%ZZ")
  }
}
