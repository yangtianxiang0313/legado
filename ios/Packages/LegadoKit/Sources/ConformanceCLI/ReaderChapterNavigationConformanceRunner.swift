import Foundation
import LegadoCore
import ReaderCore

struct ReaderChapterNavigationConformanceRun: Sendable {
  let artifact: JSONValue
  let requestPlan: JSONValue
}

enum ReaderChapterNavigationConformanceRunner {
  static let fixtureID = "rl-reader-session-chapter-navigation-001"

  static func run(
    fixtureDirectory: URL
  ) throws -> ReaderChapterNavigationConformanceRun {
    let inputDocument = try json(
      at: fixtureDirectory.appendingPathComponent("input.json")
    )
    guard
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
        inputCase["operation"] == .string("reader_chapter_navigation"),
        case .object(let arguments)? = inputCase["arguments"]
      else {
        throw MinimalTaskConformanceError.invalidFixture
      }
      plans.append(
        .object([
          "operation": .string("reader_chapter_navigation"),
          "arguments": .object(arguments),
        ])
      )
      cases.append(
        .object([
          "id": .string(id),
          "operation": .string("reader_chapter_navigation"),
          "result": try projection(arguments),
          "issue": .null,
        ])
      )
    }

    let requestPlan = JSONValue.array(plans)
    return ReaderChapterNavigationConformanceRun(
      artifact: .object([
        "schema_version": number(1),
        "fixture_id": .string(fixtureID),
        "engine": .object([
          "platform": .string("ios"),
          "revision": .string("reader-chapter-navigation-v1"),
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
    let chapterIndex = try integer("chapter_index", arguments)
    let chapterPosition = try integer("chapter_position", arguments)
    let state = ReaderChapterNavigationState(
      chapterCount: try integer("chapter_size", arguments),
      runtimeChapterIndex: chapterIndex,
      runtimeChapterPosition: chapterPosition,
      storedChapterIndex: chapterIndex,
      storedChapterPosition: chapterPosition,
      previous: try window(
        key: "previous_page_starts",
        chapterIndex: chapterIndex - 1,
        arguments: arguments
      ),
      current: try window(
        key: "current_page_starts",
        chapterIndex: chapterIndex,
        arguments: arguments
      ),
      next: try window(
        key: "next_page_starts",
        chapterIndex: chapterIndex + 1,
        arguments: arguments
      )
    )
    let outcome = AndroidReaderChapterNavigation.apply(
      try action(arguments),
      to: state
    )
    return .object([
      "moved": .bool(outcome.moved),
      "runtime_chapter_index": number(
        outcome.state.runtimeChapterIndex
      ),
      "runtime_chapter_position": number(
        outcome.state.runtimeChapterPosition
      ),
      "stored_chapter_index": number(
        outcome.state.storedChapterIndex
      ),
      "stored_chapter_position": number(
        outcome.state.storedChapterPosition
      ),
      "previous_window_position": optional(
        outcome.state.previous?.chapterIndex
      ),
      "current_window_position": optional(
        outcome.state.current?.chapterIndex
      ),
      "next_window_position": optional(
        outcome.state.next?.chapterIndex
      ),
      "events": .array(outcome.effects.map(event)),
    ])
  }

  private static func action(
    _ arguments: [String: JSONValue]
  ) throws -> ReaderChapterNavigationAction {
    guard case .string(let value)? = arguments["action"] else {
      throw MinimalTaskConformanceError.invalidFixture
    }
    switch value {
    case "next_page":
      return .nextPage
    case "previous_page":
      return .previousPage
    case "next_chapter":
      return .nextChapter
    case "previous_chapter":
      return .previousChapter(
        toLast: try optionalBoolean("to_last", arguments) ?? true
      )
    default:
      throw MinimalTaskConformanceError.invalidFixture
    }
  }

  private static func window(
    key: String,
    chapterIndex: Int,
    arguments: [String: JSONValue]
  ) throws -> ReaderChapterWindow? {
    guard let value = arguments[key] else {
      return nil
    }
    guard case .array(let values) = value else {
      throw MinimalTaskConformanceError.invalidFixture
    }
    return ReaderChapterWindow(
      chapterIndex: chapterIndex,
      pageStarts: try values.map(integer)
    )
  }

  private static func event(
    _ effect: ReaderChapterNavigationEffect
  ) -> JSONValue {
    switch effect {
    case .refreshContent(let resetPageOffset):
      return .object([
        "type": .string("up_content"),
        "reset_page_offset": .bool(resetPageOffset),
      ])
    case .refreshMenu:
      return .object(["type": .string("up_menu")])
    case .pageChanged:
      return .object(["type": .string("page_changed")])
    }
  }

  private static func integer(
    _ key: String,
    _ object: [String: JSONValue]
  ) throws -> Int {
    guard let value = object[key] else {
      throw MinimalTaskConformanceError.invalidFixture
    }
    return try integer(value)
  }

  private static func integer(_ value: JSONValue) throws -> Int {
    guard
      case .number(let number) = value,
      let result = Int(number.rawToken)
    else {
      throw MinimalTaskConformanceError.invalidFixture
    }
    return result
  }

  private static func optionalBoolean(
    _ key: String,
    _ object: [String: JSONValue]
  ) throws -> Bool? {
    guard let value = object[key] else {
      return nil
    }
    guard case .bool(let result) = value else {
      throw MinimalTaskConformanceError.invalidFixture
    }
    return result
  }

  private static func optional(_ value: Int?) -> JSONValue {
    value.map(number) ?? .null
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
