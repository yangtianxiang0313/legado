import Foundation
import LegadoCore
import ReaderCore

struct ReaderSessionCloseConformanceRun: Sendable {
  let artifact: JSONValue
  let requestPlan: JSONValue
}

enum ReaderSessionCloseConformanceRunner {
  static let fixtureID = "rl-reader-session-close-cancellation-001"

  static func run(
    fixtureDirectory: URL
  ) throws -> ReaderSessionCloseConformanceRun {
    let input = try json(
      at: fixtureDirectory.appendingPathComponent("input.json")
    )
    guard
      case .object(let root) = input,
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
        inputCase["operation"] == .string("reader_session_close"),
        case .object(let arguments)? = inputCase["arguments"],
        case .bool(let callbackMatches)? = arguments["callback_matches"]
      else {
        throw MinimalTaskConformanceError.invalidFixture
      }
      plans.append(
        .object([
          "operation": .string("reader_session_close"),
          "arguments": .object(arguments),
        ]))
      cases.append(
        .object([
          "id": .string(id),
          "operation": .string("reader_session_close"),
          "result": projection(callbackMatches: callbackMatches),
          "issue": .null,
        ]))
    }
    let requestPlan = JSONValue.array(plans)
    return ReaderSessionCloseConformanceRun(
      artifact: .object([
        "schema_version": number(1),
        "fixture_id": .string(fixtureID),
        "engine": .object([
          "platform": .string("ios"),
          "revision": .string("reader-session-close-v1"),
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
    callbackMatches: Bool
  ) -> JSONValue {
    let registered = "registered"
    let outcome = AndroidReaderSessionClosePolicy.close(
      ReaderSessionCloseState(
        callbackID: registered,
        message: "closing",
        preDownloadIsActive: true,
        downloadChildrenAreActive: true,
        mainChildrenAreActive: true,
        downloadedChapterCount: 2,
        downloadFailureCount: 1,
        imageCacheEntryCount: 1,
        loadingChapterIndices: [7, 8],
        previousLayoutListenerIsAttached: true,
        currentLayoutListenerIsAttached: true,
        nextLayoutListenerIsAttached: true
      ),
      invokingCallbackID: callbackMatches ? registered : "foreign"
    )
    let state = outcome.state
    return .object([
      "callback_cleared": .bool(state.callbackID == nil),
      "message_cleared": .bool(state.message == nil),
      "pre_download_cancelled": .bool(!state.preDownloadIsActive),
      "download_children_cancelled":
        .bool(!state.downloadChildrenAreActive),
      "main_children_cancelled": .bool(!state.mainChildrenAreActive),
      "downloaded_chapters_cleared":
        .bool(state.downloadedChapterCount == 0),
      "download_failures_cleared":
        .bool(state.downloadFailureCount == 0),
      "image_cache_cleared": .bool(state.imageCacheEntryCount == 0),
      "current_layout_listener_cleared":
        .bool(!state.currentLayoutListenerIsAttached),
      "previous_layout_listener_preserved":
        .bool(state.previousLayoutListenerIsAttached),
      "next_layout_listener_preserved":
        .bool(state.nextLayoutListenerIsAttached),
      "loading_indices": .array(
        state.loadingChapterIndices.map(number)
      ),
    ])
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
