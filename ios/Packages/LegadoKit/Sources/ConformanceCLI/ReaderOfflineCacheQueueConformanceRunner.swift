import Foundation
import LegadoCore
import ReaderCore

struct ReaderOfflineCacheQueueConformanceRun: Sendable {
  let artifact: JSONValue
  let requestPlan: JSONValue
}

enum ReaderOfflineCacheQueueConformanceRunner {
  static let fixtureID = "rl-reader-cache-offline-queue-001"

  static func run(
    fixtureDirectory: URL
  ) throws -> ReaderOfflineCacheQueueConformanceRun {
    let input = try json(
      at: fixtureDirectory.appendingPathComponent("input.json")
    )
    guard
      case .object(let root) = input,
      root["schema_version"] == number(1),
      case .array(let values)? = root["cases"]
    else {
      throw MinimalTaskConformanceError.invalidFixture
    }

    var identifiers: Set<String> = []
    var plans: [JSONValue] = []
    var cases: [JSONValue] = []
    for value in values {
      guard
        case .object(let inputCase) = value,
        case .string(let id)? = inputCase["id"],
        identifiers.insert(id).inserted,
        inputCase["operation"]
          == .string("content_cache_queue_completion"),
        case .object(let arguments)? = inputCase["arguments"]
      else {
        throw MinimalTaskConformanceError.invalidFixture
      }
      plans.append(
        .object([
          "operation": .string("content_cache_queue_completion"),
          "arguments": .object(arguments),
        ])
      )
      cases.append(
        .object([
          "id": .string(id),
          "operation": .string("content_cache_queue_completion"),
          "result": try projection(arguments),
          "issue": .null,
        ])
      )
    }

    let requestPlan = JSONValue.array(plans)
    return ReaderOfflineCacheQueueConformanceRun(
      artifact: .object([
        "schema_version": number(1),
        "fixture_id": .string(fixtureID),
        "engine": .object([
          "platform": .string("ios"),
          "revision": .string("reader-offline-cache-queue-v1"),
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
    switch try string("mode", in: arguments) {
    case "aggregate_clear":
      return try aggregateClear(arguments)
    case "retry_budget":
      return try retryBudget(arguments)
    case "close_recreate":
      return try closeRecreate(arguments)
    default:
      throw MinimalTaskConformanceError.invalidFixture
    }
  }

  private static func aggregateClear(
    _ arguments: [String: JSONValue]
  ) throws -> JSONValue {
    let bookID = try string("book_url", in: arguments)
    var queue = ReaderOfflineCacheQueue()
    let first = queue.register(bookID: bookID)
    let second = queue.register(bookID: bookID + "#second")
    queue.enqueue([1, 2, 3], for: first)
    queue.begin(1, for: first)
    queue.enqueue([5, 6], for: second)
    queue.recordTerminalFailure(for: first)
    queue.recordTerminalSuccess(for: second)
    let before = queue.summary.androidDisplayText
    queue.clearResults()
    guard
      let firstState = queue.state(for: first),
      let secondState = queue.state(for: second)
    else {
      throw MinimalTaskConformanceError.invalidFixture
    }
    return .object([
      "before_clear_summary": .string(before),
      "after_clear_summary": .string(queue.summary.androidDisplayText),
      "registered_model_count": number(queue.registeredModelCount),
      "is_run_after_clear": .bool(firstState.isRun || secondState.isRun),
      "first_state_after_clear": stateValue(firstState),
      "second_state_after_clear": stateValue(secondState),
    ])
  }

  private static func retryBudget(
    _ arguments: [String: JSONValue]
  ) throws -> JSONValue {
    let bookID = try string("book_url", in: arguments)
    let chapterIndex = try integer("chapter_index", in: arguments)
    let concurrentIndex = try integer("concurrent_index", in: arguments)
    let stoppedIndex = try integer("stopped_index", in: arguments)
    var queue = ReaderOfflineCacheQueue()

    let ordinary = queue.register(bookID: bookID)
    queue.enqueue([chapterIndex], for: ordinary)
    var attempts: [JSONValue] = []
    for attempt in 1...3 {
      queue.begin(chapterIndex, for: ordinary)
      guard let transition = queue.fail(
        chapterIndex,
        kind: .ordinary,
        for: ordinary
      ) else {
        throw MinimalTaskConformanceError.invalidFixture
      }
      attempts.append(
        .object([
          "attempt": number(attempt),
          "error_count": number(transition.errorCount),
          "requeued": .bool(transition.requeued),
          "waiting_during_backoff": .bool(
            transition.waitingDuringBackoff
          ),
        ])
      )
    }

    let concurrent = queue.register(bookID: bookID + "#concurrent")
    queue.enqueue([concurrentIndex], for: concurrent)
    queue.begin(concurrentIndex, for: concurrent)
    guard let concurrentTransition = queue.fail(
      concurrentIndex,
      kind: .concurrent,
      for: concurrent
    ) else {
      throw MinimalTaskConformanceError.invalidFixture
    }

    let stopped = queue.register(bookID: bookID + "#stopped")
    queue.enqueue([stoppedIndex], for: stopped)
    queue.begin(stoppedIndex, for: stopped)
    queue.stop(stopped)
    guard
      let stoppedTransition = queue.fail(
        stoppedIndex,
        kind: .ordinary,
        for: stopped
      ),
      let ordinaryState = queue.state(for: ordinary)
    else {
      throw MinimalTaskConformanceError.invalidFixture
    }

    return .object([
      "ordinary_attempts": .array(attempts),
      "ordinary_is_stop_after_budget": .bool(ordinaryState.isStop),
      "concurrent_error_count": number(concurrentTransition.errorCount),
      "concurrent_requeued": .bool(concurrentTransition.requeued),
      "stopped_error_count": number(stoppedTransition.errorCount),
      "stopped_requeued": .bool(stoppedTransition.requeued),
      "stopped_is_stop": .bool(stoppedTransition.state.isStop),
    ])
  }

  private static func closeRecreate(
    _ arguments: [String: JSONValue]
  ) throws -> JSONValue {
    let bookID = try string("book_url", in: arguments)
    let freshIndex = try integer("fresh_index", in: arguments)
    var queue = ReaderOfflineCacheQueue()
    let old = queue.register(bookID: bookID)
    queue.enqueue([2, 3, 4], for: old)
    queue.begin(2, for: old)
    guard
      let before = queue.state(for: old),
      let closed = queue.close(old)
    else {
      throw MinimalTaskConformanceError.invalidFixture
    }
    let emptyAfterClose = queue.registeredModelCount == 0
    let summaryAfterClose = queue.summary.androidDisplayText
    let fresh = queue.register(bookID: bookID)
    queue.enqueue([freshIndex], for: fresh)
    guard let freshState = queue.state(for: fresh) else {
      throw MinimalTaskConformanceError.invalidFixture
    }
    return .object([
      "before_close": stateValue(before),
      "closed_model": stateValue(closed),
      "registry_empty_after_close": .bool(emptyAfterClose),
      "summary_after_close": .string(summaryAfterClose),
      "fresh_is_distinct": .bool(fresh != old),
      "fresh_state": stateValue(freshState),
      "registry_count_after_recreate": number(queue.registeredModelCount),
    ])
  }

  private static func stateValue(
    _ state: ReaderOfflineCacheModelState
  ) -> JSONValue {
    .object([
      "is_run": .bool(state.isRun),
      "is_stop": .bool(state.isStop),
      "on_download_count": number(state.onDownloadCount),
      "on_download_indices": .array(
        state.downloadingChapterIndices.map(number)
      ),
      "wait_count": number(state.waitCount),
      "wait_indices": .array(state.waitingChapterIndices.map(number)),
    ])
  }

  private static func string(
    _ key: String,
    in object: [String: JSONValue]
  ) throws -> String {
    guard case .string(let value)? = object[key] else {
      throw MinimalTaskConformanceError.invalidFixture
    }
    return value
  }

  private static func integer(
    _ key: String,
    in object: [String: JSONValue]
  ) throws -> Int {
    guard
      case .number(let value)? = object[key],
      let integer = Int(value.rawToken)
    else {
      throw MinimalTaskConformanceError.invalidFixture
    }
    return integer
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
