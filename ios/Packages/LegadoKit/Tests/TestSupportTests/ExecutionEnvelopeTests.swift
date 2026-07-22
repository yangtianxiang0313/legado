import Foundation
import XCTest

@testable import TestSupport

final class ExecutionEnvelopeTests: XCTestCase {
  func testArtifactIsByteStableExplicitlyNullAndPreservesArbitraryNumbers() throws {
    let envelope = try makeEnvelope(
      platform: .ios,
      revision: "ios-revision",
      profile: "android-legado-v1",
      result: ExecutionResult(
        type: "json",
        exactJSON: Data("12345678901234567890123456789012345678901234567890".utf8)
      )
    )

    let first = try ExecutionEnvelopeCodec.artifactData(envelope)
    let second = try ExecutionEnvelopeCodec.artifactData(envelope)
    let text = String(decoding: first, as: UTF8.self)

    XCTAssertEqual(first, second)
    XCTAssertTrue(text.contains(#""decode":null"#))
    XCTAssertTrue(text.contains("12345678901234567890123456789012345678901234567890"))
    XCTAssertFalse(text.contains("trace_id"))
    XCTAssertFalse(text.contains("duration"))
    XCTAssertFalse(text.contains("run_started_at"))
  }

  func testComparisonExcludesPlatformAndRevisionButKeepsProfile() throws {
    let ios = try makeEnvelope(
      platform: .ios,
      revision: "ios-revision",
      profile: "android-legado-v1",
      result: ExecutionResult(
        type: "json",
        exactJSON: Data(#""same\r\nsemantic\rtext""#.utf8)
      )
    )
    let android = try makeEnvelope(
      platform: .android,
      revision: "android-revision",
      profile: "android-legado-v1",
      result: ExecutionResult(
        type: "json",
        exactJSON: Data(#""same\nsemantic\ntext""#.utf8)
      )
    )
    let otherProfile = try makeEnvelope(
      platform: .android,
      revision: "android-revision",
      profile: "other-profile",
      result: ExecutionResult(
        type: "json",
        exactJSON: Data(#""same\nsemantic\ntext""#.utf8)
      )
    )

    XCTAssertNotEqual(
      try ExecutionEnvelopeCodec.artifactData(ios),
      try ExecutionEnvelopeCodec.artifactData(android)
    )
    XCTAssertEqual(
      try ExecutionEnvelopeCodec.comparisonData(ios),
      try ExecutionEnvelopeCodec.comparisonData(android)
    )
    XCTAssertNotEqual(
      try ExecutionEnvelopeCodec.comparisonData(ios),
      try ExecutionEnvelopeCodec.comparisonData(otherProfile)
    )
  }

  private func makeEnvelope(
    platform: ExecutionPlatform,
    revision: String,
    profile: String,
    result: ExecutionResult
  ) throws -> ExecutionEnvelope {
    let fixture = try FixtureLoader.load(from: FixtureTestPaths.offlineFixture)
    return ExecutionEnvelope(
      fixtureID: "fixture-001",
      engine: ExecutionEngine(
        platform: platform,
        revision: revision,
        compatibilityProfile: profile
      ),
      requestPlan: [.init(request: fixture.request)],
      decode: nil,
      stages: [try ExecutionStage(stage: .transport, outcome: .completed)],
      result: result,
      issues: []
    )
  }
}
