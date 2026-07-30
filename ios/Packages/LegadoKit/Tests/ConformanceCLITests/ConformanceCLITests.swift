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
        at:
          temporaryRoot
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

  func testMinimalTaskRunnerMatchesAppStartupAndroidGolden() async throws {
    let temporaryRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let fixtureID = AppStartupConformanceRunner.fixtureID
    let fixturePath = "ios/harness/fixtures/runtime-lab/\(fixtureID)"
    let goldenPath =
      "ios/harness/goldens/android-legado-v1/\(fixtureID).json"
    let taskPath = "ios/project/loop/task.json"
    for relative in [fixturePath, goldenPath, taskPath] {
      try FileManager.default.createDirectory(
        at:
          temporaryRoot
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
        "id": "IOS-APP-NAVIGATION-STARTUP-FIRST-USE-RESTORE-001",
        "source": [
          "fixture_id": fixtureID,
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
    XCTAssertTrue(text.contains(#""status":"equal""#))
    XCTAssertTrue(text.contains(#""first_divergence":null"#))
    XCTAssertTrue(
      text.contains(
        #""dialog_sequence":["privacy","help","local_password"]"#
      )
    )
    XCTAssertTrue(
      text.contains(
        #""downstream_start_sequence":["MainActivity","ReadBookActivity"]"#
      )
    )
  }

  func testMinimalTaskRunnerMatchesDOMSelectorAndroidGolden() async throws {
    let temporaryRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let fixtureID = "sl-source-rule-dom-selector-backends-001"
    let fixturePath = "ios/harness/fixtures/source-lab/\(fixtureID)"
    let goldenPath =
      "ios/harness/goldens/android-legado-v1/\(fixtureID).json"
    let taskPath = "ios/project/loop/task.json"
    for relative in [fixturePath, goldenPath, taskPath] {
      try FileManager.default.createDirectory(
        at:
          temporaryRoot
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
        "id": "IOS-SOURCE-RUNTIME-DOM-SELECTOR-BACKENDS-001",
        "source": [
          "fixture_id": fixtureID,
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
    XCTAssertTrue(text.contains(#""status":"equal""#))
    XCTAssertTrue(text.contains(#""first_divergence":null"#))
    XCTAssertTrue(text.contains(#""tag":"JX_TEXT""#))
    XCTAssertTrue(
      text.contains(
        #""exception_type":"org.seimicrawler.xpath.exception.XpathSyntaxErrorException""#
      )
    )
  }

  func testMinimalTaskRunnerMatchesJSONPathRegexAndroidGolden() async throws {
    let temporaryRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let fixtureID = "sl-source-rule-jsonpath-regex-backends-001"
    let fixturePath = "ios/harness/fixtures/source-lab/\(fixtureID)"
    let goldenPath =
      "ios/harness/goldens/android-legado-v1/\(fixtureID).json"
    let taskPath = "ios/project/loop/task.json"
    for relative in [fixturePath, goldenPath, taskPath] {
      try FileManager.default.createDirectory(
        at:
          temporaryRoot
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
        "id": "IOS-SOURCE-RUNTIME-JSONPATH-REGEX-BACKENDS-001",
        "source": [
          "fixture_id": fixtureID,
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
    XCTAssertTrue(text.contains(#""status":"equal""#))
    XCTAssertTrue(text.contains(#""first_divergence":null"#))
    XCTAssertTrue(text.contains(#""prefix-Alpha-Beta""#))
    XCTAssertTrue(
      text.contains(
        #""exception_type":"java.util.regex.PatternSyntaxException""#
      )
    )
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
        at:
          temporaryRoot
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

  func testMinimalTaskRunnerMatchesRequestOptionLayeringAndroidGolden() async throws {
    let temporaryRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let fixtureID = "sl-source-request-header-cookie-retry-layering-001"
    let fixturePath = "ios/harness/fixtures/source-lab/\(fixtureID)"
    let goldenPath = "ios/harness/goldens/android-legado-v1/\(fixtureID).json"
    let taskPath = "ios/project/loop/task.json"
    for relative in [fixturePath, goldenPath, taskPath] {
      try FileManager.default.createDirectory(
        at:
          temporaryRoot
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
        "id": "IOS-SOURCE-RUNTIME-HEADER-COOKIE-RETRY-001",
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
        #""value":"persisted=stored; shared=stored; explicit=option""#
      )
    )
    XCTAssertTrue(
      text.contains(
        #""route_request_counts":[{"request_count":3,"route_id":"retry-two-with-header-cookie"},{"request_count":1,"route_id":"retry-default"}]"#
      )
    )
  }

  func testMinimalTaskRunnerMatchesFieldEncodingAndroidGolden() async throws {
    let temporaryRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let fixtureID = "sl-source-request-field-encoding-runtime-001"
    let fixturePath = "ios/harness/fixtures/source-lab/\(fixtureID)"
    let goldenPath = "ios/harness/goldens/android-legado-v1/\(fixtureID).json"
    let taskPath = "ios/project/loop/task.json"
    for relative in [fixturePath, goldenPath, taskPath] {
      try FileManager.default.createDirectory(
        at:
          temporaryRoot
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
        "id": "IOS-SOURCE-RUNTIME-FIELD-ENCODING-001",
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
    XCTAssertTrue(text.contains(#""value":"%D0%C7%BA%D3""#))
    XCTAssertTrue(text.contains(#""value":"%u661f%20%u6cb3%2b%25""#))
    XCTAssertTrue(text.contains(#""code":"rule_failed""#))
  }

  func testMinimalTaskRunnerMatchesURLTemplateAndroidGolden() async throws {
    let temporaryRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let fixtureID = "sl-source-request-url-template-compilation-001"
    let fixturePath = "ios/harness/fixtures/source-lab/\(fixtureID)"
    let goldenPath = "ios/harness/goldens/android-legado-v1/\(fixtureID).json"
    let taskPath = "ios/project/loop/task.json"
    for relative in [fixturePath, goldenPath, taskPath] {
      try FileManager.default.createDirectory(
        at:
          temporaryRoot
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
        "id": "IOS-SOURCE-RUNTIME-URL-TEMPLATE-COMPILATION-001",
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
    XCTAssertTrue(text.contains(#""rule_url":"../template//last""#))
    XCTAssertTrue(text.contains(#""url":"http://sourcelab.test/template/3/second""#))
    XCTAssertTrue(text.contains(#""query_string":"term=星河""#))
  }

  func testMinimalTaskRunnerMatchesRateLimitAndroidGolden() async throws {
    let temporaryRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let fixtureID = "sl-source-session-rate-limit-shared-state-001"
    let fixturePath = "ios/harness/fixtures/source-lab/\(fixtureID)"
    let goldenPath = "ios/harness/goldens/android-legado-v1/\(fixtureID).json"
    let taskPath = "ios/project/loop/task.json"
    for relative in [fixturePath, goldenPath, taskPath] {
      try FileManager.default.createDirectory(
        at:
          temporaryRoot
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
        "id": "IOS-SOURCE-RUNTIME-RATE-LIMIT-001",
        "source": [
          "fixture_id": fixtureID,
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
    XCTAssertTrue(text.contains(#""first_divergence":null"#))
    XCTAssertTrue(text.contains(#""allowed_before_denial":3"#))
    XCTAssertTrue(text.contains(#""after_end_still_denied":true"#))
    XCTAssertTrue(text.contains(#""is_count_window":true"#))
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

  func testBookDetailProjectionKeepsLocalFormatActions() throws {
    let run = try BookDetailActionConformanceRunner.run(
      fixtureDirectory: fixture(
        "ios/harness/fixtures/runtime-lab/"
          + "rl-ui-book-detail-conditional-actions-001"
      )
    )
    guard
      case .object(let artifact) = run.artifact,
      case .object(let result)? = artifact["result"],
      result["type"] == .string("ui_runtime"),
      case .object(let value)? = result["value"],
      case .object(let projection)? =
        value["portable_known_projection"],
      case .array(let cases)? = projection["cases"],
      cases.count == 6,
      case .object(let localTXT) = cases[4],
      case .object(let localTXTResult)? = localTXT["result"],
      case .object(let localTXTActions)? =
        localTXTResult["actions"],
      case .object(let localEPUB) = cases[5],
      case .object(let localEPUBResult)? = localEPUB["result"],
      case .object(let localEPUBActions)? =
        localEPUBResult["actions"]
    else {
      return XCTFail("Invalid book detail projection")
    }

    XCTAssertEqual(
      localTXTActions["split_long_chapter"],
      .bool(true)
    )
    XCTAssertEqual(localTXTActions["upload"], .bool(true))
    XCTAssertEqual(
      localEPUBActions["split_long_chapter"],
      .bool(false)
    )
    XCTAssertEqual(localEPUBActions["upload"], .bool(true))
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

  func testMinimalTaskRunnerMatchesBookmarkRuntimeAndroidGolden() async throws {
    let temporaryRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let fixtureID =
      "rl-reader-bookmark-search-runtime-risk-001"
    let fixturePath =
      "ios/harness/fixtures/runtime-lab/\(fixtureID)"
    let goldenPath =
      "ios/harness/goldens/android-legado-v1/\(fixtureID).json"
    let taskPath = "ios/project/loop/task.json"
    for relative in [fixturePath, goldenPath, taskPath] {
      try FileManager.default.createDirectory(
        at:
          temporaryRoot
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
    try JSONSerialization.data(
      withJSONObject: [
        "schema_version": 2,
        "id": "IOS-READER-CORE-BOOKMARK-SEARCH-001",
        "source": [
          "fixture_id": fixtureID,
          "android_golden": goldenPath,
        ],
      ],
      options: [.sortedKeys]
    ).write(to: temporaryRoot.appendingPathComponent(taskPath))

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
    XCTAssertTrue(text.contains(#""first_divergence":null"#))
    XCTAssertTrue(text.contains(#""status":"equal""#))
    XCTAssertTrue(text.contains(#""book_name":"乙书""#))
    XCTAssertTrue(text.contains(#""time":701"#))
  }

  func testMinimalTaskRunnerMatchesReaderProgressAndroidGolden()
    async throws
  {
    let temporaryRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let fixtureID =
      "rl-reader-progress-layout-save-runtime-001"
    let fixturePath =
      "ios/harness/fixtures/runtime-lab/\(fixtureID)"
    let goldenPath =
      "ios/harness/goldens/android-legado-v1/\(fixtureID).json"
    let taskPath = "ios/project/loop/task.json"
    for relative in [fixturePath, goldenPath, taskPath] {
      try FileManager.default.createDirectory(
        at:
          temporaryRoot
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
    try JSONSerialization.data(
      withJSONObject: [
        "schema_version": 2,
        "id": "IOS-READER-CORE-PROGRESS-LAYOUT-SAVE-001",
        "source": [
          "fixture_id": fixtureID,
          "android_golden": goldenPath,
        ],
      ],
      options: [.sortedKeys]
    ).write(to: temporaryRoot.appendingPathComponent(taskPath))

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
    XCTAssertTrue(text.contains(#""first_divergence":null"#))
    XCTAssertTrue(text.contains(#""status":"equal""#))
    XCTAssertTrue(text.contains(#""persisted_char_position":260"#))
    XCTAssertTrue(text.contains(#""page_index":-1"#))
    XCTAssertTrue(text.contains(#""persisted_chapter_title":"第二章""#))
  }

  func testMinimalTaskRunnerMatchesRuleCombinationAndroidGolden() async throws {
    let temporaryRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let fixtureID =
      "sl-source-rule-combination-and-coercion-runtime-001"
    let fixturePath = "ios/harness/fixtures/source-lab/\(fixtureID)"
    let goldenPath =
      "ios/harness/goldens/android-legado-v1/\(fixtureID).json"
    let taskPath = "ios/project/loop/task.json"
    for relative in [fixturePath, goldenPath, taskPath] {
      try FileManager.default.createDirectory(
        at:
          temporaryRoot
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
    try JSONSerialization.data(
      withJSONObject: [
        "schema_version": 2,
        "id": "IOS-SOURCE-RUNTIME-RULE-COMBINATION-COERCION-001",
        "source": [
          "fixture_id": fixtureID,
          "android_golden": goldenPath,
        ],
      ],
      options: [.sortedKeys]
    ).write(to: temporaryRoot.appendingPathComponent(taskPath))

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
    XCTAssertTrue(text.contains(#""first_divergence":null"#))
    XCTAssertTrue(text.contains(#""status":"equal""#))
    XCTAssertTrue(text.contains(#""Alpha|Beta""#))
    XCTAssertTrue(text.contains(#""com.script.ScriptException""#))
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

final class ReaderCoreTests: XCTestCase {
  func testBookmarkProjectionContainsAllSevenGoldenCases() throws {
    let text = try projectionText()

    XCTAssertTrue(text.contains(#""id":"same-book-chapter-name""#))
    XCTAssertTrue(text.contains(#""id":"content-branch-cross-book""#))
    XCTAssertTrue(text.contains(#""id":"empty-key-cross-book""#))
    XCTAssertTrue(text.contains(#""id":"percent-wildcard""#))
    XCTAssertTrue(text.contains(#""id":"underscore-wildcard""#))
    XCTAssertTrue(text.contains(#""id":"global-chapter-order""#))
    XCTAssertTrue(text.contains(#""id":"time-primary-key-replace""#))
  }

  func testBookmarkProjectionPreservesCrossBookContentResult() throws {
    let text = try projectionText()

    XCTAssertTrue(text.contains(#""book_name":"乙书""#))
    XCTAssertTrue(text.contains(#""content":"needle in foreign""#))
    XCTAssertTrue(text.contains(#""time":202"#))
  }

  func testBookmarkProjectionPreservesWildcardResults() throws {
    let text = try projectionText()

    XCTAssertTrue(text.contains(#""key":"%""#))
    XCTAssertTrue(text.contains(#""key":"_""#))
    XCTAssertTrue(text.contains(#""content":"y""#))
  }

  func testBookmarkProjectionPreservesGlobalOrder() throws {
    let text = try projectionText()
    let start = try XCTUnwrap(
      text.range(of: #""id":"global-chapter-order""#)
    )
    let result = text[start.lowerBound...]
    let two = try XCTUnwrap(result.range(of: #""time":602"#))
    let five = try XCTUnwrap(result.range(of: #""time":603"#))
    let eight = try XCTUnwrap(result.range(of: #""time":601"#))

    XCTAssertLessThan(two.lowerBound, five.lowerBound)
    XCTAssertLessThan(five.lowerBound, eight.lowerBound)
  }

  func testBookmarkProjectionReplacesSameTimeWithLastRow() throws {
    let text = try projectionText()

    XCTAssertTrue(text.contains(#""book_name":"新书""#))
    XCTAssertTrue(text.contains(#""content":"新内容""#))
  }

  func testReadRecordProjectionContainsAllSixGoldenCases() throws {
    let text = try readRecordProjectionText()

    XCTAssertTrue(text.contains(#""id":"all-device-aggregate-query""#))
    XCTAssertTrue(text.contains(#""id":"reset-loads-all-device-total""#))
    XCTAssertTrue(text.contains(#""id":"empty-device-write-recounts-foreign""#))
    XCTAssertTrue(text.contains(#""id":"pause-save-leaves-tail-unsettled""#))
    XCTAssertTrue(text.contains(#""id":"disabled-recording-preserves-session-start""#))
    XCTAssertTrue(text.contains(#""id":"composite-key-replace-isolated-by-device""#))
  }

  func testReadRecordProjectionPreservesAggregateRisk() throws {
    let text = try readRecordProjectionText()

    XCTAssertTrue(text.contains(#""all_device_read_time":230"#))
    XCTAssertTrue(text.contains(#""session_read_time":230"#))
    XCTAssertTrue(text.contains(#""foreign_device_total":200"#))
    XCTAssertTrue(text.contains(#""foreign_time_counted_twice":true"#))
  }

  func testReadRecordProjectionPreservesUnsettledBoundaries() throws {
    let text = try readRecordProjectionText()

    XCTAssertTrue(text.contains(#""save_read_settled_session_time":false"#))
    XCTAssertTrue(text.contains(#""read_start_time_unchanged":true"#))
    XCTAssertTrue(text.contains(#""persisted_row_count":0"#))
  }

  func testReadRecordProjectionReplacesOnlyMatchingCompositeKey() throws {
    let text = try readRecordProjectionText()
    let start = try XCTUnwrap(
      text.range(of: #""id":"composite-key-replace-isolated-by-device""#)
    )
    let result = text[start.lowerBound...]

    XCTAssertTrue(result.contains(#""row_count":3"#))
    XCTAssertTrue(result.contains(#""device_id":"","last_read":5004,"read_time":40"#))
    XCTAssertTrue(result.contains(#""device_id":"device-a","last_read":5005,"read_time":15"#))
    XCTAssertTrue(result.contains(#""device_id":"device-b","last_read":5003,"read_time":20"#))
  }

  func testProgressProjectionContainsAllTenGoldenCases() throws {
    let text = try progressProjectionText()

    XCTAssertTrue(text.contains(#""id":"page-index-maps-to-layout-char-position""#))
    XCTAssertTrue(text.contains(#""id":"negative-page-index-resets-to-zero""#))
    XCTAssertTrue(
      text.contains(
        #""id":"oversized-page-index-clamps-to-last-layout-page""#
      )
    )
    XCTAssertTrue(text.contains(#""id":"completed-layout-maps-char-boundaries""#))
    XCTAssertTrue(
      text.contains(
        #""id":"incomplete-layout-rejects-position-past-page-end""#
      )
    )
    XCTAssertTrue(
      text.contains(
        #""id":"page-save-same-chapter-preserves-existing-title""#
      )
    )
    XCTAssertTrue(
      text.contains(
        #""id":"page-save-after-chapter-switch-refreshes-title""#
      )
    )
    XCTAssertTrue(text.contains(#""id":"pause-default-save-refreshes-title""#))
    XCTAssertTrue(
      text.contains(
        #""id":"reset-clamps-chapter-index-without-immediate-write""#
      )
    )
    XCTAssertTrue(
      text.contains(
        #""id":"audio-save-refreshes-title-and-persists-book-fields""#
      )
    )
  }

  func testProgressProjectionPreservesLayoutBoundaries() throws {
    let text = try progressProjectionText()

    XCTAssertTrue(text.contains(#""requested_page_index":-1"#))
    XCTAssertTrue(text.contains(#""requested_page_index":99"#))
    XCTAssertTrue(text.contains(#""persisted_char_position":260"#))
    XCTAssertTrue(text.contains(#""char_index":266,"page_index":-1"#))
    XCTAssertTrue(text.contains(#""char_index":1000,"page_index":2"#))
  }

  func testProgressProjectionPreservesSaveTitleRules() throws {
    let text = try progressProjectionText()

    XCTAssertTrue(text.contains(#""persisted_chapter_title":"既有标题""#))
    XCTAssertTrue(text.contains(#""persisted_chapter_title":"第一章""#))
    XCTAssertTrue(text.contains(#""persisted_chapter_title":"第二章""#))
    XCTAssertTrue(text.contains(#""last_check_count":0"#))
  }

  func testProgressProjectionKeepsResetPersistenceSeparate() throws {
    let text = try progressProjectionText()
    let start = try XCTUnwrap(
      text.range(
        of: #""id":"reset-clamps-chapter-index-without-immediate-write""#
      )
    )
    let result = text[start.lowerBound...]

    XCTAssertTrue(result.contains(#""runtime_chapter_index":2"#))
    XCTAssertTrue(result.contains(#""persisted_chapter_index":99"#))
    XCTAssertTrue(result.contains(#""persisted_char_position":777"#))
  }

  func testSaveCommandFreezesIdentityAndProgressAtTriggerTime() {
    let result = ReaderProgressSaveProductProbe.captureCommands()

    XCTAssertTrue(result.firstCommandStayedFrozen)
    XCTAssertTrue(result.identityStayedBoundToOriginalBook)
    XCTAssertEqual(result.firstSequence, 1)
    XCTAssertEqual(result.secondSequence, 2)
  }

  func testProgressPersistenceRejectsStaleGeneration() async throws {
    let rejected =
      try await ReaderProgressSaveProductProbe
      .rejectsStaleGeneration()

    XCTAssertTrue(rejected)
  }

  func testProgressFlushUsesExactSessionIdentity() async throws {
    let flushed =
      try await ReaderProgressSaveProductProbe
      .flushesExactIdentity()

    XCTAssertTrue(flushed)
  }

  func testPrefetchProjectionContainsAllEightGoldenCases() throws {
    let text = try prefetchProjectionText()

    XCTAssertTrue(text.contains(#""id":"local-book-does-not-create-task""#))
    XCTAssertTrue(
      text.contains(
        #""id":"configuration-below-two-disables-prefetch""#
      )
    )
    XCTAssertTrue(
      text.contains(
        #""id":"minimum-enabled-prefetches-both-directions""#
      )
    )
    XCTAssertTrue(
      text.contains(
        #""id":"window-skips-adjacent-current-and-state""#
      )
    )
    XCTAssertTrue(text.contains(#""id":"window-clamps-at-book-start""#))
    XCTAssertTrue(text.contains(#""id":"window-clamps-at-book-end""#))
    XCTAssertTrue(
      text.contains(
        #""id":"two-direction-workers-start-concurrently""#
      )
    )
    XCTAssertTrue(
      text.contains(
        #""id":"new-invocation-cancels-previous-policy-job""#
      )
    )
  }

  func testPrefetchProjectionPreservesWindowAndSkipRules() throws {
    let text = try prefetchProjectionText()

    XCTAssertTrue(
      text.contains(
        #""downloaded_indices":[1,3,7,8,9]"#
      )
    )
    XCTAssertTrue(
      text.contains(
        #""failure_counts":[{"count":2,"index":1},{"count":3,"index":2}]"#
      )
    )
    XCTAssertTrue(text.contains(#""downloaded_indices":[2,3,4]"#))
    XCTAssertTrue(text.contains(#""downloaded_indices":[0,1,2]"#))
  }

  func testPrefetchProjectionPreservesWorkersAndReplacement() throws {
    let text = try prefetchProjectionText()

    XCTAssertTrue(text.contains(#""child_job_count":2"#))
    XCTAssertTrue(text.contains(#""initial_loading_indices":[3,7]"#))
    XCTAssertTrue(text.contains(#""first_task_cancelled":true"#))
    XCTAssertTrue(text.contains(#""replacement_current_chapter":6"#))
    XCTAssertTrue(text.contains(#""task_identity_changed":true"#))
  }

  func testTOCRemapProjectionContainsAllElevenGoldenCases() throws {
    let text = try tocRemapProjectionText()

    XCTAssertTrue(
      text.contains(
        #""id":"old-index-zero-short-circuits-empty-toc""#
      )
    )
    XCTAssertTrue(
      text.contains(#""id":"empty-new-toc-preserves-old-index""#)
    )
    XCTAssertTrue(
      text.contains(#""id":"cleaned-title-finds-inserted-chapter""#)
    )
    XCTAssertTrue(
      text.contains(#""id":"duplicate-cleaned-title-selects-first""#)
    )
    XCTAssertTrue(
      text.contains(#""id":"chapter-number-exact-match-recovers""#)
    )
    XCTAssertTrue(
      text.contains(
        #""id":"nearest-number-without-exact-match-falls-back""#
      )
    )
    XCTAssertTrue(
      text.contains(
        #""id":"fallback-clamps-high-index-to-new-last""#
      )
    )
    XCTAssertTrue(
      text.contains(
        #""id":"old-size-ratio-expands-search-to-index-zero""#
      )
    )
    XCTAssertTrue(
      text.contains(
        #""id":"old-size-ratio-excludes-early-title""#
      )
    )
    XCTAssertTrue(
      text.contains(
        #""id":"jaccard-exactly-point-nine-six-falls-back""#
      )
    )
    XCTAssertTrue(
      text.contains(
        #""id":"jaccard-above-point-nine-six-selects-title""#
      )
    )
  }

  func testTOCRemapProjectionPreservesEmptyAndFallbackResults() throws {
    let text = try tocRemapProjectionText()

    XCTAssertTrue(
      text.contains(
        #""new_chapter_count":0,"selected_index":7,"selected_index_in_bounds":false,"selected_title":null"#
      )
    )
    XCTAssertTrue(
      text.contains(
        #""new_chapter_count":3,"selected_index":2,"selected_index_in_bounds":true,"selected_title":"终篇 新月""#
      )
    )
    XCTAssertTrue(
      text.contains(
        #""new_chapter_count":30,"selected_index":20,"selected_index_in_bounds":true,"selected_title":"占位20""#
      )
    )
  }

  func testTOCRemapProjectionPreservesStrictMatchingRules() throws {
    let text = try tocRemapProjectionText()

    XCTAssertTrue(
      text.contains(
        #""new_chapter_count":7,"selected_index":5,"selected_index_in_bounds":true,"selected_title":"第4章 星河归途""#
      )
    )
    XCTAssertTrue(
      text.contains(
        #""new_chapter_count":15,"selected_index":7,"selected_index_in_bounds":true,"selected_title":"第十章 重逢""#
      )
    )
    XCTAssertTrue(
      text.contains(
        #""new_chapter_count":8,"selected_index":6,"selected_index_in_bounds":true,"selected_title":"第42回 陌路""#
      )
    )
    XCTAssertTrue(
      text.contains(
        #""new_chapter_count":4,"selected_index":1,"selected_index_in_bounds":true,"selected_title":"fallback""#
      )
    )
    XCTAssertTrue(
      text.contains(
        #""new_chapter_count":4,"selected_index":3,"selected_index_in_bounds":true,"selected_title":"abcdefghijklmnopqrstuvwxyz""#
      )
    )
  }

  private func projectionText() throws -> String {
    let fixture = repositoryRoot.appendingPathComponent(
      "ios/harness/fixtures/runtime-lab/"
        + ReaderBookmarkFixtureProjection.fixtureID,
      isDirectory: true
    )
    let run = try ReaderBookmarkFixtureProjection.run(
      caseData: Data(
        contentsOf: fixture.appendingPathComponent("case.json")
      ),
      inputData: Data(
        contentsOf: fixture.appendingPathComponent("input.json")
      )
    )
    return String(
      decoding: try JSONValueCodec.encode(run.artifact),
      as: UTF8.self
    )
  }

  private func readRecordProjectionText() throws -> String {
    let fixture = repositoryRoot.appendingPathComponent(
      "ios/harness/fixtures/runtime-lab/"
        + ReaderReadRecordFixtureProjection.fixtureID,
      isDirectory: true
    )
    let run = try ReaderReadRecordFixtureProjection.run(
      caseData: Data(
        contentsOf: fixture.appendingPathComponent("case.json")
      ),
      inputData: Data(
        contentsOf: fixture.appendingPathComponent("input.json")
      )
    )
    return String(
      decoding: try JSONValueCodec.encode(run.artifact),
      as: UTF8.self
    )
  }

  private func progressProjectionText() throws -> String {
    let fixture = repositoryRoot.appendingPathComponent(
      "ios/harness/fixtures/runtime-lab/"
        + ReaderProgressFixtureProjection.fixtureID,
      isDirectory: true
    )
    let run = try ReaderProgressFixtureProjection.run(
      caseData: Data(
        contentsOf: fixture.appendingPathComponent("case.json")
      ),
      inputData: Data(
        contentsOf: fixture.appendingPathComponent("input.json")
      )
    )
    return String(
      decoding: try JSONValueCodec.encode(run.artifact),
      as: UTF8.self
    )
  }

  private func prefetchProjectionText() throws -> String {
    let fixture = repositoryRoot.appendingPathComponent(
      "ios/harness/fixtures/runtime-lab/"
        + ReaderPrefetchFixtureProjection.fixtureID,
      isDirectory: true
    )
    let run = try ReaderPrefetchFixtureProjection.run(
      caseData: Data(
        contentsOf: fixture.appendingPathComponent("case.json")
      ),
      inputData: Data(
        contentsOf: fixture.appendingPathComponent("input.json")
      )
    )
    return String(
      decoding: try JSONValueCodec.encode(run.artifact),
      as: UTF8.self
    )
  }

  private func tocRemapProjectionText() throws -> String {
    let fixture = repositoryRoot.appendingPathComponent(
      "ios/harness/fixtures/runtime-lab/"
        + ReaderTOCRemapFixtureProjection.fixtureID,
      isDirectory: true
    )
    let run = try ReaderTOCRemapFixtureProjection.run(
      caseData: Data(
        contentsOf: fixture.appendingPathComponent("case.json")
      ),
      inputData: Data(
        contentsOf: fixture.appendingPathComponent("input.json")
      )
    )
    return String(
      decoding: try JSONValueCodec.encode(run.artifact),
      as: UTF8.self
    )
  }

  private var repositoryRoot: URL {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<6 {
      root.deleteLastPathComponent()
    }
    return root
  }
}

private enum TestError: Error {
  case invalidArtifact
}
