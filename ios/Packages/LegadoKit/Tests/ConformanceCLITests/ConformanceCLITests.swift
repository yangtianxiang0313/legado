import Foundation
import LegadoCore
import XCTest

@testable import ConformanceCLI
@testable import TestSupport

final class ConformanceCLITests: XCTestCase {
  func testHarnessDependencyIsAvailable() {
    XCTAssertEqual(TestSupportModule.identifier, "TestSupport")
  }

  func testMinimalTaskRunnerEmitsStructuredAndroidComparison() async throws {
    let temporaryRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let fixturePath = "ios/harness/fixtures/source-lab/sl-post-form-001"
    let goldenPath = "ios/harness/goldens/android-legado-v1/sl-post-form-001.json"
    let taskPath = "ios/project/loop/task.json"
    for relative in [fixturePath, goldenPath, taskPath] {
      try FileManager.default.createDirectory(
        at: temporaryRoot
          .appendingPathComponent(relative)
          .deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
    }
    try FileManager.default.copyItem(
      at: repositoryRoot.appendingPathComponent(fixturePath),
      to: temporaryRoot.appendingPathComponent(fixturePath)
    )
    try FileManager.default.copyItem(
      at: repositoryRoot.appendingPathComponent(goldenPath),
      to: temporaryRoot.appendingPathComponent(goldenPath)
    )
    let task = try JSONSerialization.data(
      withJSONObject: [
        "schema_version": 2,
        "id": "IOS-SOURCE-RUNTIME-POST-FORM-001",
        "source": [
          "fixture_id": "sl-post-form-001",
          "android_golden": goldenPath,
        ],
      ],
      options: [.sortedKeys]
    )
    try task.write(to: temporaryRoot.appendingPathComponent(taskPath))
    let first = try await MinimalTaskConformanceRunner.run(
      taskPath: taskPath,
      repositoryRoot: temporaryRoot
    )
    let second = try await MinimalTaskConformanceRunner.run(
      taskPath: taskPath,
      repositoryRoot: temporaryRoot
    )
    let text = String(decoding: first.data, as: UTF8.self)

    XCTAssertTrue(first.passed)
    XCTAssertEqual(first.data, second.data)
    XCTAssertTrue(text.contains(#""android_expected""#))
    XCTAssertTrue(text.contains(#""ios_actual""#))
    XCTAssertTrue(text.contains(#""canonical_request_plan""#))
    XCTAssertTrue(text.contains(#""first_divergence":null"#))
    XCTAssertTrue(text.contains(#""dup","value":"second""#))
    XCTAssertFalse(text.contains(#""dup","value":"first""#))
  }

  func testMinimalTaskRunnerMatchesXMLResponseAndroidGolden() async throws {
    let temporaryRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let fixtureID =
      "sl-source-response-xml-declaration-normalization-001"
    let fixturePath = "ios/harness/fixtures/source-lab/\(fixtureID)"
    let goldenPath =
      "ios/harness/goldens/android-legado-v1/\(fixtureID).json"
    let taskPath = "ios/project/loop/task.json"
    for relative in [fixturePath, goldenPath, taskPath] {
      try FileManager.default.createDirectory(
        at: temporaryRoot
          .appendingPathComponent(relative)
          .deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
    }
    try FileManager.default.copyItem(
      at: repositoryRoot.appendingPathComponent(fixturePath),
      to: temporaryRoot.appendingPathComponent(fixturePath)
    )
    try FileManager.default.copyItem(
      at: repositoryRoot.appendingPathComponent(goldenPath),
      to: temporaryRoot.appendingPathComponent(goldenPath)
    )
    let task = try JSONSerialization.data(
      withJSONObject: [
        "schema_version": 2,
        "id": "IOS-SOURCE-RUNTIME-XML-RESPONSE-001",
        "source": [
          "fixture_id": fixtureID,
          "android_golden": goldenPath,
        ],
      ],
      options: [.sortedKeys]
    )
    try task.write(to: temporaryRoot.appendingPathComponent(taskPath))

    let run = try await MinimalTaskConformanceRunner.run(
      taskPath: taskPath,
      repositoryRoot: temporaryRoot
    )
    let text = String(decoding: run.data, as: UTF8.self)

    XCTAssertTrue(run.passed)
    XCTAssertTrue(text.contains(#""first_divergence":null"#))
    XCTAssertTrue(
      text.contains(
        #"<?xml version=\"1.0\"?><feed><title>星河</title></feed>\n"#
      )
    )
    XCTAssertTrue(text.contains(#""operation":"raw_response""#))
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

  func testSourceFormatFixturesUseSeparateLosslessAndPortableLanesWithoutRequests() async throws {
    for fixtureID in sourceFormatFixtureIDs {
      let first = try await ConformanceRunner.run(
        fixtureDirectory: fixture("ios/harness/fixtures/source-format/\(fixtureID)")
      )
      let second = try await ConformanceRunner.run(
        fixtureDirectory: fixture("ios/harness/fixtures/source-format/\(fixtureID)")
      )
      let artifact = try JSONValueCodec.decode(first)
      let lanes = try sourceFormatLanes(artifact)

      XCTAssertEqual(first, second)
      XCTAssertEqual(try requestPlan(artifact), [])
      XCTAssertNotNil(lanes["fixture_integrity"])
      XCTAssertNotNil(lanes["portable_known_projection"])
      XCTAssertNotNil(lanes["ios_lossless_extension"])
      XCTAssertNil(lanes["android_characterization"])
    }
  }

  func testUnknownAndPresenceValuesRemainLosslessButAreNotPortableUnknowns() async throws {
    let artifact = try JSONValueCodec.decode(
      await ConformanceRunner.run(
        fixtureDirectory: fixture(
          "ios/harness/fixtures/source-format/source-format-unknown-fields-001"
        )
      )
    )
    let lanes = try sourceFormatLanes(artifact)
    let input = try nestedObject(lanes, "fixture_integrity", "canonical_input")
    let projection = try object(lanes["portable_known_projection"])
    let roundTrip = try nestedObject(lanes, "ios_lossless_extension", "canonical_round_trip")

    XCTAssertEqual(input, roundTrip)
    XCTAssertNil(projection["xObject"])
    XCTAssertNil(projection["xInteger"])
    XCTAssertEqual(projection["bookSourceName"], .string("unknown"))
    guard case .number(let integer)? = input["xInteger"] else {
      return XCTFail("missing exact unknown integer")
    }
    XCTAssertEqual(integer.rawToken, "123456789012345678901234567890")
    guard
      case .object(let search)? = projection["ruleSearch"],
      case .string("known")? = search["name"]
    else {
      return XCTFail("known nested field was not projected")
    }
    XCTAssertNil(search["xNested"])
  }

  func testMinimalFixtureDoesNotMaterializeAndroidDefaults() async throws {
    let output = try await ConformanceRunner.run(
      fixtureDirectory: fixture("ios/harness/fixtures/source-format/source-format-minimal-001")
    )
    let text = String(decoding: output, as: UTF8.self)

    XCTAssertFalse(text.contains("respondTime"))
    XCTAssertFalse(text.contains("enabledExplore"))
    XCTAssertFalse(text.contains("ruleSearch"))
  }

  func testPortableProjectionUsesStrictNonNullInputMaskAndCanonicalIntegers() async throws {
    let artifact = try JSONValueCodec.decode(
      await ConformanceRunner.run(
        fixtureDirectory: fixture(
          "ios/harness/fixtures/source-format/source-format-null-missing-empty-001"
        )
      )
    )
    let lanes = try sourceFormatLanes(artifact)
    let projection = try object(lanes["portable_known_projection"])
    let roundTrip = try nestedObject(
      lanes,
      "ios_lossless_extension",
      "canonical_round_trip"
    )

    XCTAssertNil(projection["bookSourceType"])
    XCTAssertNil(projection["bookUrlPattern"])
    XCTAssertNil(projection["enabled"])
    XCTAssertNil(projection["respondTime"])
    XCTAssertNil(projection["weight"])
    XCTAssertNil(projection["ruleSearch"])
    XCTAssertEqual(projection["bookSourceComment"], .string(""))
    XCTAssertEqual(projection["variableComment"], .string("value"))
    XCTAssertEqual(try numberToken(projection["customOrder"]), "0")
    XCTAssertEqual(try numberToken(projection["lastUpdateTime"]), "-9223372036854775808")
    XCTAssertEqual(try numberToken(roundTrip["customOrder"]), "-0")
    XCTAssertEqual(try object(projection["ruleBookInfo"]), [:])
    let toc = try object(projection["ruleToc"])
    XCTAssertNil(toc["chapterName"])
    XCTAssertEqual(toc["chapterUrl"], .string(""))
    XCTAssertEqual(toc["chapterList"], .string("value"))
  }

  func testRuleFixtureProjectsAllThirtyRootFieldsAndSixtyTwoRuleFields() async throws {
    let artifact = try JSONValueCodec.decode(
      await ConformanceRunner.run(
        fixtureDirectory: fixture(
          "ios/harness/fixtures/source-format/source-format-rule-groups-001"
        )
      )
    )
    let projection = try object(
      try sourceFormatLanes(artifact)["portable_known_projection"]
    )
    let expectedRootFields: Set<String> = [
      "bookSourceUrl", "bookSourceName", "bookSourceGroup", "bookSourceType",
      "bookUrlPattern", "customOrder", "enabled", "enabledExplore", "jsLib",
      "enabledCookieJar", "concurrentRate", "header", "loginUrl", "loginUi",
      "loginCheckJs", "coverDecodeJs", "bookSourceComment", "variableComment",
      "lastUpdateTime", "respondTime", "weight", "exploreUrl", "exploreScreen",
      "ruleExplore", "searchUrl", "ruleSearch", "ruleBookInfo", "ruleToc",
      "ruleContent", "ruleReview",
    ]
    let ruleFieldCounts = [
      "ruleSearch": 11,
      "ruleExplore": 10,
      "ruleBookInfo": 12,
      "ruleToc": 10,
      "ruleContent": 9,
      "ruleReview": 10,
    ]

    XCTAssertEqual(Set(projection.keys), expectedRootFields)
    XCTAssertEqual(ruleFieldCounts.values.reduce(0, +), 62)
    for (ruleName, expectedCount) in ruleFieldCounts {
      XCTAssertEqual(try object(projection[ruleName]).count, expectedCount, ruleName)
    }
  }

  private var offlineFixture: URL {
    fixture("ios/harness/fixtures/conformance/harness-offline-001")
  }

  private var sourceLabFixture: URL {
    fixture("ios/harness/fixtures/source-lab/sl-html-basic-001")
  }

  private let sourceFormatFixtureIDs = [
    "source-format-minimal-001",
    "source-format-unknown-fields-001",
    "source-format-null-missing-empty-001",
    "source-format-rule-groups-001",
  ]

  private var repositoryRoot: URL {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<6 {
      root.deleteLastPathComponent()
    }
    return root
  }

  private func fixture(_ path: String) -> URL {
    repositoryRoot.appendingPathComponent(path, isDirectory: true)
  }

  private func sourceFormatLanes(_ artifact: JSONValue) throws -> [String: JSONValue] {
    guard
      case .object(let root) = artifact,
      case .object(let result)? = root["result"],
      case .object(let lanes)? = result["value"]
    else {
      throw TestError.invalidArtifact
    }
    return lanes
  }

  private func requestPlan(_ artifact: JSONValue) throws -> [JSONValue] {
    guard case .object(let root) = artifact, case .array(let plan)? = root["request_plan"] else {
      throw TestError.invalidArtifact
    }
    return plan
  }

  private func nestedObject(
    _ object: [String: JSONValue],
    _ first: String,
    _ second: String
  ) throws -> [String: JSONValue] {
    guard case .object(let parent)? = object[first] else { throw TestError.invalidArtifact }
    return try self.object(parent[second])
  }

  private func object(_ value: JSONValue?) throws -> [String: JSONValue] {
    guard case .object(let object)? = value else { throw TestError.invalidArtifact }
    return object
  }

  private func numberToken(_ value: JSONValue?) throws -> String {
    guard case .number(let number)? = value else { throw TestError.invalidArtifact }
    return number.rawToken
  }

}

private enum TestError: Error {
  case invalidArtifact
}
