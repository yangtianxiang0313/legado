import CryptoKit
import Foundation
import LegadoCore
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

  func testWorkItemRunnerUsesManagedManifestAndIsByteStable() async throws {
    let first = try await ConformanceWorkItemRunner.run(
      workItemID: "IOS-SOURCE-FORMAT-FIXTURES-001",
      repositoryRoot: repositoryRoot
    )
    let second = try await ConformanceWorkItemRunner.run(
      workItemID: "IOS-SOURCE-FORMAT-FIXTURES-001",
      repositoryRoot: repositoryRoot
    )
    let value = try JSONValueCodec.decode(first)
    guard
      case .object(let root) = value,
      case .array(let fixtures)? = root["fixtures"]
    else {
      return XCTFail("invalid work-item aggregate")
    }

    XCTAssertEqual(first, second)
    XCTAssertEqual(fixtures.count, 4)
    XCTAssertFalse(String(decoding: first, as: UTF8.self).contains("golden"))
  }

  func testWorkItemRunnerRejectsStaleFixtureDigest() async throws {
    let temporaryRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let harnessRoot = temporaryRoot.appendingPathComponent("ios/harness", isDirectory: true)
    try FileManager.default.createDirectory(
      at: harnessRoot,
      withIntermediateDirectories: true
    )
    try FileManager.default.copyItem(
      at: repositoryRoot.appendingPathComponent("ios/harness/work-items", isDirectory: true),
      to: harnessRoot.appendingPathComponent("work-items", isDirectory: true)
    )
    try FileManager.default.copyItem(
      at: repositoryRoot.appendingPathComponent("ios/harness/fixtures", isDirectory: true),
      to: harnessRoot.appendingPathComponent("fixtures", isDirectory: true)
    )
    let manifestURL = harnessRoot.appendingPathComponent("fixtures/manifest.json")
    let manifest = try staleManifest(
      try JSONValueCodec.decode(Data(contentsOf: manifestURL)),
      fixtureID: "source-format-minimal-001"
    )
    try JSONValueCodec.encode(manifest).write(to: manifestURL, options: .atomic)

    do {
      _ = try await ConformanceWorkItemRunner.run(
        workItemID: "IOS-SOURCE-FORMAT-FIXTURES-001",
        repositoryRoot: temporaryRoot
      )
      XCTFail("stale fixture digest must fail closed")
    } catch let error as ConformanceWorkItemError {
      XCTAssertEqual(error, .fixtureDigestMismatch)
    }
  }

  func testWorkItemRunnerExecutesSourceRuntimeAndMatchesProtectedAndroidGolden() async throws {
    let first = try await ConformanceWorkItemRunner.run(
      workItemID: "IOS-SOURCE-RUNTIME-GOLDEN-CONFORMANCE-001",
      repositoryRoot: repositoryRoot
    )
    let second = try await ConformanceWorkItemRunner.run(
      workItemID: "IOS-SOURCE-RUNTIME-GOLDEN-CONFORMANCE-001",
      repositoryRoot: repositoryRoot
    )
    let value = try JSONValueCodec.decode(first)
    guard
      case .object(let root) = value,
      case .array(let fixtures)? = root["fixtures"],
      fixtures.count == 1,
      case .object(let artifact) = fixtures[0],
      case .object(let result)? = artifact["result"],
      result["type"] == .string("source_pipeline"),
      case .object(let lanes)? = result["value"],
      case .object(let projection)? = lanes["portable_known_projection"],
      case .array(let cases)? = projection["cases"],
      case .array(let requests)? = artifact["request_plan"],
      case .object(let comparison)? = artifact["golden_comparison"]
    else {
      return XCTFail("invalid source pipeline conformance artifact")
    }

    XCTAssertEqual(first, second)
    XCTAssertEqual(cases.count, 8)
    XCTAssertEqual(requests.count, 8)
    XCTAssertEqual(comparison["status"], .string("equal"))
    XCTAssertEqual(comparison["expected_sha256"], comparison["actual_sha256"])
    XCTAssertEqual(comparison["first_divergence"], .null)
    XCTAssertEqual(
      cases.compactMap { value -> String? in
        guard case .object(let item) = value, case .string(let id)? = item["id"] else {
          return nil
        }
        return id
      },
      [
        "search-hit",
        "search-empty",
        "book-detail",
        "book-detail-missing-cover",
        "toc",
        "toc-empty",
        "chapter",
        "chapter-second",
      ]
    )
    let text = String(decoding: first, as: UTF8.self)
    XCTAssertTrue(text.contains("星河纪事"))
    XCTAssertFalse(text.contains("book-not-found"))
    XCTAssertFalse(text.contains("chapter-not-found"))
    XCTAssertFalse(text.lowercased().contains("<!doctype"))
  }

  func testWorkItemRunnerReportsDeterministicFirstGoldenDivergence() async throws {
    let temporaryRoot = try copiedConformanceRoot()
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let goldenURL = temporaryRoot.appendingPathComponent(
      "ios/harness/goldens/android-legado-v1/sl-html-basic-001.json"
    )
    let golden = try replacingGoldenSearchName(
      try JSONValueCodec.decode(Data(contentsOf: goldenURL)),
      with: "故意制造的差异"
    )
    let goldenData = try JSONValueCodec.encode(golden)
    try goldenData.write(to: goldenURL, options: .atomic)
    try updateGoldenDigest(sha256(goldenData), repositoryRoot: temporaryRoot)

    do {
      _ = try await ConformanceWorkItemRunner.run(
        workItemID: "IOS-SOURCE-RUNTIME-GOLDEN-CONFORMANCE-001",
        repositoryRoot: temporaryRoot
      )
      XCTFail("golden divergence must fail closed")
    } catch let error as GoldenProjectionMismatch {
      XCTAssertEqual(error.fixtureID, "sl-html-basic-001")
      XCTAssertEqual(error.difference.kind, .valueMismatch)
      XCTAssertEqual(
        error.difference.jsonPointer,
        "/cases/0/result/books/0/name"
      )
      XCTAssertEqual(
        error.description,
        "golden_projection_mismatch:sl-html-basic-001:value_mismatch:/cases/0/result/books/0/name"
      )
    }
  }

  func testWorkItemRunnerRejectsGoldenDigestDriftBeforeComparison() async throws {
    let temporaryRoot = try copiedConformanceRoot()
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let goldenURL = temporaryRoot.appendingPathComponent(
      "ios/harness/goldens/android-legado-v1/sl-html-basic-001.json"
    )
    var data = try Data(contentsOf: goldenURL)
    data.append(0x20)
    try data.write(to: goldenURL, options: .atomic)

    do {
      _ = try await ConformanceWorkItemRunner.run(
        workItemID: "IOS-SOURCE-RUNTIME-GOLDEN-CONFORMANCE-001",
        repositoryRoot: temporaryRoot
      )
      XCTFail("golden digest drift must fail closed")
    } catch let error as ConformanceWorkItemError {
      XCTAssertEqual(error, .goldenDigestMismatch)
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

  private func staleManifest(_ value: JSONValue, fixtureID: String) throws -> JSONValue {
    guard
      case .object(var root) = value,
      case .array(let fixtures)? = root["fixtures"]
    else {
      throw TestError.invalidArtifact
    }
    root["fixtures"] = .array(
      fixtures.map { fixture in
        guard
          case .object(var entry) = fixture,
          entry["id"] == .string(fixtureID)
        else { return fixture }
        entry["sha256"] = .string(String(repeating: "0", count: 64))
        return .object(entry)
      }
    )
    return .object(root)
  }

  private func copiedConformanceRoot() throws -> URL {
    let temporaryRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let harnessRoot = temporaryRoot.appendingPathComponent("ios/harness", isDirectory: true)
    try FileManager.default.createDirectory(
      at: harnessRoot,
      withIntermediateDirectories: true
    )
    for directory in ["work-items", "fixtures", "goldens"] {
      try FileManager.default.copyItem(
        at: repositoryRoot.appendingPathComponent("ios/harness/\(directory)", isDirectory: true),
        to: harnessRoot.appendingPathComponent(directory, isDirectory: true)
      )
    }
    return temporaryRoot
  }

  private func replacingGoldenSearchName(
    _ value: JSONValue,
    with replacement: String
  ) throws -> JSONValue {
    guard
      case .object(var root) = value,
      case .object(var artifact)? = root["artifact"],
      case .object(var result)? = artifact["result"],
      case .object(var lanes)? = result["value"],
      case .object(var projection)? = lanes["portable_known_projection"],
      case .array(var cases)? = projection["cases"],
      case .object(var first) = cases[0],
      case .object(var firstResult)? = first["result"],
      case .array(var books)? = firstResult["books"],
      case .object(var book) = books[0]
    else {
      throw TestError.invalidArtifact
    }
    book["name"] = .string(replacement)
    books[0] = .object(book)
    firstResult["books"] = .array(books)
    first["result"] = .object(firstResult)
    cases[0] = .object(first)
    projection["cases"] = .array(cases)
    lanes["portable_known_projection"] = .object(projection)
    result["value"] = .object(lanes)
    artifact["result"] = .object(result)
    root["artifact"] = .object(artifact)
    return .object(root)
  }

  private func updateGoldenDigest(_ digest: String, repositoryRoot: URL) throws {
    let manifestURL = repositoryRoot.appendingPathComponent(
      "ios/harness/goldens/manifest.json"
    )
    guard
      case .object(var root) = try JSONValueCodec.decode(Data(contentsOf: manifestURL)),
      case .object(var fixtures)? = root["fixtures"],
      case .object(var fixture)? = fixtures["sl-html-basic-001"]
    else {
      throw TestError.invalidArtifact
    }
    fixture["golden_sha256"] = .string(digest)
    fixtures["sl-html-basic-001"] = .object(fixture)
    root["fixtures"] = .object(fixtures)
    try JSONValueCodec.encode(.object(root)).write(to: manifestURL, options: .atomic)
  }

  private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

private enum TestError: Error {
  case invalidArtifact
}
