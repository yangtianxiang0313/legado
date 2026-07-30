import Foundation
import LegadoCore
import ReaderCore

struct ReaderContentAcquisitionConformanceRun: Sendable {
  let artifact: JSONValue
  let requestPlan: JSONValue
}

enum ReaderContentAcquisitionConformanceRunner {
  static let fixtureID =
    "rl-reader-content-cache-first-acquisition-001"

  static func run(
    fixtureDirectory: URL
  ) throws -> ReaderContentAcquisitionConformanceRun {
    let caseDocument = try json(
      at: fixtureDirectory.appendingPathComponent("case.json")
    )
    let inputDocument = try json(
      at: fixtureDirectory.appendingPathComponent("input.json")
    )
    guard
      case .object(let caseRoot) = caseDocument,
      caseRoot["id"] == .string(fixtureID),
      caseRoot["kind"] == .string("android_runtime_scenario"),
      caseRoot["operation"] == .string("android_runtime"),
      case .object(let inputRoot) = inputDocument,
      case .array(let inputCases)? = inputRoot["cases"]
    else {
      throw MinimalTaskConformanceError.invalidFixture
    }

    var identifiers: Set<String> = []
    var plans: [JSONValue] = []
    var cases: [JSONValue] = []
    for value in inputCases {
      guard
        case .object(let inputCase) = value,
        case .string(let id)? = inputCase["id"],
        identifiers.insert(id).inserted,
        inputCase["operation"] == .string("reader_content_acquisition"),
        case .object(let arguments)? = inputCase["arguments"]
      else {
        throw MinimalTaskConformanceError.invalidFixture
      }
      plans.append(
        .object([
          "operation": .string("reader_content_acquisition"),
          "arguments": .object(arguments),
        ])
      )
      cases.append(
        .object([
          "id": .string(id),
          "operation": .string("reader_content_acquisition"),
          "result": try projection(arguments),
          "issue": .null,
        ])
      )
    }

    let requestPlan = JSONValue.array(plans)
    return ReaderContentAcquisitionConformanceRun(
      artifact: .object([
        "schema_version": number(1),
        "fixture_id": .string(fixtureID),
        "engine": .object([
          "platform": .string("ios"),
          "revision": .string("reader-content-acquisition-v1"),
          "compatibility_profile": .string("android-legado-v1"),
        ]),
        "request_plan": requestPlan,
        "decode": .null,
        "stages": .array([]),
        "result": .object([
          "type": .string("reader_runtime"),
          "value": .object([
            "portable_known_projection": .object([
              "cases": .array(cases)
            ])
          ]),
        ]),
        "issues": .array([]),
      ]),
      requestPlan: requestPlan
    )
  }

  private static func projection(
    _ arguments: [String: JSONValue]
  ) throws -> JSONValue {
    let chapterMode = try string("chapter_mode", arguments)
    let bookKind = try string("book_kind", arguments)
    let cacheMode = try string("cache_mode", arguments)
    let cachedContent = try string("cached_content", arguments)
    let sourceMode = try string("source_mode", arguments)
    guard
      ["present", "missing"].contains(chapterMode),
      ["remote", "local"].contains(bookKind),
      ["text", "empty", "missing"].contains(cacheMode),
      ["missing", "present_invalid_url"].contains(sourceMode)
    else {
      throw MinimalTaskConformanceError.invalidFixture
    }

    let context = ReaderContentAcquisitionContext(
      chapterExists: chapterMode == "present",
      cachedContent: cacheMode == "text" ? cachedContent : nil,
      isLocalBook: bookKind == "local",
      localReadResult:
        bookKind == "local" ? .failure(message: nil) : nil,
      sourceAvailable: sourceMode != "missing"
    )
    let plan = AndroidReaderContentAcquisitionPolicy.plan(for: context)
    let sourceResult: ReaderContentReadResult? =
      sourceMode == "present_invalid_url"
        ? .failure(message: "invalid_url")
        : nil
    let outcome = AndroidReaderContentAcquisitionPolicy.complete(
      plan,
      sourceResult: sourceResult
    )
    return .object([
      "initial_content_state":
        .string(outcome.initialContentState.rawValue),
      "initial_content": optional(outcome.initialContent),
      "cached_content_after_load":
        .string(outcome.cachedContentAfterLoad.rawValue),
      "content_after_load": optional(outcome.contentAfterLoad),
      "chapter_loaded": .bool(outcome.chapterLoaded),
      "source_present": .bool(outcome.sourcePresent),
      "source_delegated": .bool(outcome.sourceDelegated),
      "download_failure_count":
        number(outcome.downloadFailureCount),
      "download_marked_success":
        .bool(outcome.downloadMarkedSuccess),
      "loading_cleared": .bool(outcome.loadingCleared),
    ])
  }

  private static func string(
    _ key: String,
    _ object: [String: JSONValue]
  ) throws -> String {
    guard case .string(let value)? = object[key] else {
      throw MinimalTaskConformanceError.invalidFixture
    }
    return value
  }

  private static func optional(_ value: String?) -> JSONValue {
    value.map(JSONValue.string) ?? .null
  }

  private static func number(_ value: Int) -> JSONValue {
    .number(JSONNumber(Int64(value)))
  }

  private static func json(at url: URL) throws -> JSONValue {
    do {
      return try JSONValueCodec.decode(
        Data(contentsOf: url, options: [.mappedIfSafe])
      )
    } catch {
      throw MinimalTaskConformanceError.invalidFixture
    }
  }
}
