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
}
