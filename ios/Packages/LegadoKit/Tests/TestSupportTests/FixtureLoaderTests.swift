import Foundation
import XCTest

@testable import TestSupport

final class FixtureLoaderTests: XCTestCase {
  func testLoadsDeterministicOfflineFixtureIntoSendableValues() throws {
    let fixture = try FixtureLoader.load(from: FixtureTestPaths.offlineFixture)

    func requireSendable<Value: Sendable>(_: Value) {}
    requireSendable(fixture)
    XCTAssertEqual(fixture.definition.id, "harness-offline-001")
    XCTAssertEqual(fixture.definition.transport.mode, .offline)
    XCTAssertFalse(fixture.definition.determinism.networkAllowed)
    XCTAssertEqual(fixture.definition.determinism.timezone, "UTC")
    XCTAssertEqual(fixture.definition.determinism.locale, "en_US_POSIX")
    XCTAssertEqual(fixture.definition.determinism.randomSeed, 7)
    XCTAssertEqual(fixture.definition.limits.timeoutMilliseconds, 1_000)
    XCTAssertEqual(fixture.request.method, .get)
    XCTAssertNil(fixture.request.body)
    XCTAssertEqual(fixture.request.timeout?.milliseconds, 1_000)
    XCTAssertEqual(fixture.routes.count, 1)
    XCTAssertFalse(fixture.sourceData.isEmpty)
  }
}

enum FixtureTestPaths {
  static var offlineFixture: URL {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<6 {
      root.deleteLastPathComponent()
    }
    return root.appendingPathComponent(
      "ios/harness/fixtures/conformance/harness-offline-001",
      isDirectory: true
    )
  }
}
