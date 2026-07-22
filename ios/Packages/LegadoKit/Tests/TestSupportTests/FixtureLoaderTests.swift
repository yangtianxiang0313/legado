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

  func testLoadsSourceLabScenarioAsLogicalOfflineRequests() throws {
    let fixture = try FixtureLoader.load(from: FixtureTestPaths.sourceLabFixture)
    let template = String(decoding: fixture.sourceTemplateData, as: UTF8.self)
    let rendered = String(decoding: fixture.sourceData, as: UTF8.self)

    XCTAssertEqual(fixture.definition.id, "sl-html-basic-001")
    XCTAssertEqual(fixture.definition.kind, "source_lab_scenario")
    XCTAssertEqual(fixture.definition.transport.mode, .fixtureAndLoopback)
    XCTAssertEqual(fixture.definition.limits.maxConcurrency, 4)
    XCTAssertEqual(fixture.logicalOrigin.absoluteString, "http://sourcelab.test")
    XCTAssertEqual(fixture.routes.count, 12)
    XCTAssertEqual(fixture.requestCases.count, 10)
    XCTAssertEqual(fixture.requestCases.first?.id, "search-hit")
    XCTAssertEqual(fixture.requestCases.last?.id, "chapter-not-found")
    XCTAssertTrue(
      fixture.requestCases.allSatisfy {
        $0.request.url.absoluteString.hasPrefix("http://sourcelab.test/")
      }
    )
    XCTAssertTrue(template.contains("${SOURCE_LAB_ORIGIN}"))
    XCTAssertFalse(rendered.contains("${SOURCE_LAB_ORIGIN}"))
    XCTAssertTrue(rendered.contains("http://sourcelab.test"))
    XCTAssertFalse(rendered.contains("127.0.0.1"))
  }

  func testLoadsSourceRoundTripFixturesWithoutTransportValues() throws {
    for fixtureID in FixtureTestPaths.sourceFormatFixtureIDs {
      let fixture = try FixtureLoader.loadForConformance(
        from: FixtureTestPaths.sourceFormatFixture(fixtureID)
      )
      guard case .sourceRoundTrip(let sourceRoundTrip) = fixture else {
        return XCTFail("expected source-round-trip fixture: \(fixtureID)")
      }
      XCTAssertEqual(sourceRoundTrip.definition.id, fixtureID)
      XCTAssertEqual(sourceRoundTrip.definition.operation, .sourceRoundTrip)
      XCTAssertEqual(sourceRoundTrip.definition.transport.mode, .offline)
      XCTAssertTrue(sourceRoundTrip.definition.transport.responses.isEmpty)
      XCTAssertEqual(sourceRoundTrip.definition.limits.maxRequests, 0)
      XCTAssertFalse(sourceRoundTrip.sourceData.isEmpty)
    }
  }

  func testExistingFixturesStillLoadThroughTransportLane() throws {
    for url in [FixtureTestPaths.offlineFixture, FixtureTestPaths.sourceLabFixture] {
      guard case .transport = try FixtureLoader.loadForConformance(from: url) else {
        return XCTFail("expected transport fixture: \(url.lastPathComponent)")
      }
    }
  }
}

enum FixtureTestPaths {
  static let sourceFormatFixtureIDs = [
    "source-format-minimal-001",
    "source-format-unknown-fields-001",
    "source-format-null-missing-empty-001",
    "source-format-rule-groups-001",
  ]

  static var offlineFixture: URL {
    fixture("ios/harness/fixtures/conformance/harness-offline-001")
  }

  static var sourceLabFixture: URL {
    fixture("ios/harness/fixtures/source-lab/sl-html-basic-001")
  }

  static func sourceFormatFixture(_ id: String) -> URL {
    fixture("ios/harness/fixtures/source-format/\(id)")
  }

  private static func fixture(_ path: String) -> URL {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<6 {
      root.deleteLastPathComponent()
    }
    return root.appendingPathComponent(path, isDirectory: true)
  }
}
