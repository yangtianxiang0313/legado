import Foundation
import LegadoCore
import ReaderCore

struct ReaderIndexLoadDedupConformanceRun: Sendable {
  let artifact: JSONValue
  let requestPlan: JSONValue
}

enum ReaderIndexLoadDedupConformanceRunner {
  static let fixtureID =
    "rl-reader-content-index-load-dedup-001"

  static func run(
    fixtureDirectory: URL
  ) throws -> ReaderIndexLoadDedupConformanceRun {
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
      case .object(let inputRoot) = inputDocument,
      case .array(let inputCases)? = inputRoot["cases"]
    else {
      throw MinimalTaskConformanceError.invalidFixture
    }

    var identifiers: Set<String> = []
    var plans: [JSONValue] = []
    var cases: [JSONValue] = []
    var safeCases: [JSONValue] = []
    for value in inputCases {
      guard
        case .object(let inputCase) = value,
        case .string(let id)? = inputCase["id"],
        identifiers.insert(id).inserted,
        inputCase["operation"] == .string("reader_index_load_dedup"),
        case .object(let arguments)? = inputCase["arguments"]
      else {
        throw MinimalTaskConformanceError.invalidFixture
      }
      plans.append(
        .object([
          "operation": .string("reader_index_load_dedup"),
          "arguments": .object(arguments),
        ])
      )
      cases.append(
        .object([
          "id": .string(id),
          "operation": .string("reader_index_load_dedup"),
          "result": try androidBaseline(arguments),
          "issue": .null,
        ])
      )
      safeCases.append(
        .object([
          "id": .string(id),
          "result": try generationSafeProjection(arguments),
        ])
      )
    }

    let requestPlan = JSONValue.array(plans)
    return ReaderIndexLoadDedupConformanceRun(
      artifact: .object([
        "schema_version": number(1),
        "fixture_id": .string(fixtureID),
        "engine": .object([
          "platform": .string("ios"),
          "revision": .string("reader-load-registry-v1"),
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
            ]),
            "ios_safety_projection": .object([
              "policy": .string("generation_index_nonce"),
              "cases": .array(safeCases),
            ]),
          ]),
        ]),
        "issues": .array([]),
      ]),
      requestPlan: requestPlan
    )
  }

  private static func androidBaseline(
    _ arguments: [String: JSONValue]
  ) throws -> JSONValue {
    let mode = try string("mode", arguments)
    let index = try integer("index", arguments)
    var active: Set<Int> = []
    var attempts: [Bool] = []
    func acquire(_ value: Int) -> Bool {
      active.insert(value).inserted
    }
    switch mode {
    case "duplicate":
      attempts = [acquire(index), acquire(index)]
    case "remove_retry":
      attempts.append(acquire(index))
      active.remove(index)
      attempts.append(acquire(index))
    case "different_indices":
      attempts = [
        acquire(index),
        acquire(try integer("other_index", arguments)),
      ]
    case "single":
      attempts = [acquire(index)]
    case "session_replacement":
      attempts.append(acquire(index))
      active.removeAll()
      attempts.append(acquire(index))
    case "stale_removal":
      attempts.append(acquire(index))
      active.removeAll()
      attempts.append(acquire(index))
      active.remove(index)
      attempts.append(acquire(index))
    default:
      throw MinimalTaskConformanceError.invalidFixture
    }
    return result(
      active: active,
      attempts: attempts,
      staleRemovalErasedReplacement: mode == "stale_removal"
    )
  }

  private static func generationSafeProjection(
    _ arguments: [String: JSONValue]
  ) throws -> JSONValue {
    let mode = try string("mode", arguments)
    let index = try integer("index", arguments)
    var registry = ReaderLoadRegistry()
    var accepted: [Bool] = []
    var oldToken: ReaderLoadToken?

    func acquire(_ value: Int) -> Bool {
      registry.acquire(chapterIndex: value) != nil
    }
    switch mode {
    case "duplicate":
      accepted = [acquire(index), acquire(index)]
    case "remove_retry":
      let token = registry.acquire(chapterIndex: index)!
      accepted.append(true)
      _ = registry.finish(token)
      accepted.append(acquire(index))
    case "different_indices":
      accepted = [
        acquire(index),
        acquire(try integer("other_index", arguments)),
      ]
    case "single":
      accepted = [acquire(index)]
    case "session_replacement", "stale_removal":
      oldToken = registry.acquire(chapterIndex: index)
      accepted.append(oldToken != nil)
      registry.beginSession()
      accepted.append(acquire(index))
      if mode == "stale_removal", let oldToken {
        let staleRemovedReplacement = registry.finish(oldToken)
        accepted.append(acquire(index))
        return .object([
          "attempt_results": .array(accepted.map(JSONValue.bool)),
          "active_indices": integers(registry.activeChapterIndices),
          "stale_removal_erased_replacement":
            .bool(staleRemovedReplacement),
        ])
      }
    default:
      throw MinimalTaskConformanceError.invalidFixture
    }
    return .object([
      "attempt_results": .array(accepted.map(JSONValue.bool)),
      "active_indices": integers(registry.activeChapterIndices),
      "stale_removal_erased_replacement": .bool(false),
    ])
  }

  private static func result(
    active: Set<Int>,
    attempts: [Bool],
    staleRemovalErasedReplacement: Bool
  ) -> JSONValue {
    .object([
      "active_indices": integers(active.sorted()),
      "attempt_results": .array(attempts.map(JSONValue.bool)),
      "stale_removal_erased_replacement":
        .bool(staleRemovalErasedReplacement),
    ])
  }

  private static func integers(_ values: [Int]) -> JSONValue {
    .array(values.map(number))
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

  private static func integer(
    _ key: String,
    _ object: [String: JSONValue]
  ) throws -> Int {
    guard
      case .number(let value)? = object[key],
      let result = Int(value.rawToken)
    else {
      throw MinimalTaskConformanceError.invalidFixture
    }
    return result
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
