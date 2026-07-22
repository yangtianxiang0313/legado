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

  func testRunnerProducesDeterministicSourceLabTranscriptWithoutSocketDetails() async throws {
    let fixture = sourceLabFixture

    let first = try await ConformanceRunner.run(fixtureDirectory: fixture)
    let second = try await ConformanceRunner.run(fixtureDirectory: fixture)
    let text = String(decoding: first, as: UTF8.self)
    let requestCount = text.components(separatedBy: #""method":"GET""#).count - 1

    XCTAssertEqual(first, second)
    XCTAssertEqual(requestCount, 10)
    XCTAssertTrue(text.contains(#""fixture_id":"sl-html-basic-001""#))
    XCTAssertTrue(text.contains(#""type":"http_response_list""#))
    XCTAssertTrue(text.contains(#""case_id":"search-hit""#))
    XCTAssertTrue(text.contains(#""case_id":"chapter-not-found""#))
    XCTAssertTrue(text.contains(#""status":404"#))
    XCTAssertTrue(text.contains("http://sourcelab.test/"))
    XCTAssertFalse(text.contains("127.0.0.1"))
    XCTAssertFalse(text.contains("${SOURCE_LAB_ORIGIN}"))
    XCTAssertFalse(text.contains("星河纪事"))
    XCTAssertFalse(text.lowercased().contains("<!doctype"))
    XCTAssertFalse(text.contains("localhost"))
  }

  private var offlineFixture: URL {
    fixture("ios/harness/fixtures/conformance/harness-offline-001")
  }

  private var sourceLabFixture: URL {
    fixture("ios/harness/fixtures/source-lab/sl-html-basic-001")
  }

  private func fixture(_ path: String) -> URL {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<6 {
      root.deleteLastPathComponent()
    }
    return root.appendingPathComponent(path, isDirectory: true)
  }
}
