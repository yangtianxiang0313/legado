import Foundation
import XCTest

@testable import ConformanceCLI
@testable import TestSupport

final class ConformanceCLITests: XCTestCase {
  func testHarnessDependencyIsAvailable() {
    XCTAssertEqual(TestSupportModule.identifier, "TestSupport")
  }

  func testRunnerProducesIdenticalCanonicalBytesWithoutRawBodyOrDynamicFields() async throws {
    let fixture = offlineFixture

    let first = try await ConformanceRunner.run(fixtureDirectory: fixture)
    let second = try await ConformanceRunner.run(fixtureDirectory: fixture)
    let text = String(decoding: first, as: UTF8.self)

    XCTAssertEqual(first, second)
    XCTAssertTrue(text.contains(#""fixture_id":"harness-offline-001""#))
    XCTAssertTrue(text.contains(#""platform":"ios""#))
    XCTAssertTrue(text.contains(#""decode":null"#))
    XCTAssertFalse(text.contains(#"{"books":[]}"#))
    XCTAssertFalse(text.contains("trace_id"))
    XCTAssertFalse(text.contains("duration"))
    XCTAssertFalse(text.contains("run_started_at"))
  }

  private var offlineFixture: URL {
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
