import Foundation
import LegadoCore
import ReaderCore

struct ReaderSessionResetConformanceRun: Sendable {
  let artifact: JSONValue
  let requestPlan: JSONValue
}

enum ReaderSessionResetConformanceRunner {
  static let fixtureID = "rl-reader-session-reset-from-book-001"

  static func run(
    fixtureDirectory: URL
  ) throws -> ReaderSessionResetConformanceRun {
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
        inputCase["operation"] == .string("reader_session_reset"),
        case .object(let arguments)? = inputCase["arguments"]
      else {
        throw MinimalTaskConformanceError.invalidFixture
      }
      plans.append(
        .object([
          "operation": .string("reader_session_reset"),
          "arguments": .object(arguments),
        ])
      )
      cases.append(
        .object([
          "id": .string(id),
          "operation": .string("reader_session_reset"),
          "result": try projection(id: id, arguments: arguments),
          "issue": .null,
        ])
      )
    }

    let requestPlan = JSONValue.array(plans)
    return ReaderSessionResetConformanceRun(
      artifact: .object([
        "schema_version": number(1),
        "fixture_id": .string(fixtureID),
        "engine": .object([
          "platform": .string("ios"),
          "revision": .string("reader-session-reset-v1"),
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
    id: String,
    arguments: [String: JSONValue]
  ) throws -> JSONValue {
    let chapterCount = try integer("chapter_count", arguments)
    let storedIndex = try integer("stored_chapter_index", arguments)
    let storedPosition = try integer("stored_chapter_pos", arguments)
    let bookKind = try string("book_kind", arguments)
    let sourceMode = try string("source_mode", arguments)
    let sourceImageStyle = try string("source_image_style", arguments)
    let bookImageStyle = try optionalString(
      "book_image_style",
      arguments
    )
    let readDurations = try integers("read_times", arguments)
    guard
      chapterCount >= 0,
      ["local", "remote"].contains(bookKind),
      ["present", "missing"].contains(sourceMode)
    else {
      throw MinimalTaskConformanceError.invalidFixture
    }

    let isLocal = bookKind == "local"
    let origin =
      isLocal
      ? "local"
      : "android-runtime://reader-session/source/\(id)"
    let source: ReaderSessionSource? =
      sourceMode == "present"
      ? ReaderSessionSource(url: origin, imageStyle: sourceImageStyle)
      : nil
    let snapshot = AndroidReaderSessionResetPolicy.reset(
      ReaderSessionResetInput(
        bookIdentity: "/android-runtime/reader-session/\(id).txt",
        bookName: "Oracle Session \(id)",
        chapterCount: chapterCount,
        storedChapterIndex: storedIndex,
        storedChapterPosition: storedPosition,
        isLocalBook: isLocal,
        bookImageStyle: bookImageStyle,
        source: source,
        readDurations: readDurations
      )
    )

    return .object([
      "book_identity": .string(snapshot.bookIdentity),
      "chapter_size": number(snapshot.chapterCount),
      "runtime_chapter_index": number(snapshot.runtimeChapterIndex),
      "runtime_chapter_pos": number(snapshot.runtimeChapterPosition),
      "stored_chapter_index": number(snapshot.storedChapterIndex),
      "stored_chapter_pos": number(snapshot.storedChapterPosition),
      "is_local_book": .bool(snapshot.isLocalBook),
      "book_source_url": optional(snapshot.sourceURL),
      "content_processor_present":
        .bool(snapshot.contentProcessorPresent),
      "book_image_style": optional(snapshot.bookImageStyle),
      "read_record_book_name": .string(snapshot.readRecordBookName),
      "read_record_time": number(snapshot.readRecordTime),
      "text_chapters_cleared": .bool(snapshot.textChaptersCleared),
      "temporary_progress_cleared":
        .bool(snapshot.temporaryProgressCleared),
      "loading_chapters_cleared":
        .bool(snapshot.loadingChaptersCleared),
      "download_state_preserved":
        .bool(snapshot.downloadStatePreserved),
      "callback_events": .array(
        snapshot.effects.map { effect in
          switch effect {
          case .refreshMenu:
            return .object(["type": .string("up_menu")])
          case .refreshPageAnimation(let updateRecorder):
            return .object([
              "type": .string("up_page_anim"),
              "up_recorder": .bool(updateRecorder),
            ])
          }
        }
      ),
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

  private static func optionalString(
    _ key: String,
    _ object: [String: JSONValue]
  ) throws -> String? {
    switch object[key] {
    case .string(let value):
      return value
    case .null:
      return nil
    default:
      throw MinimalTaskConformanceError.invalidFixture
    }
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

  private static func integers(
    _ key: String,
    _ object: [String: JSONValue]
  ) throws -> [Int] {
    guard case .array(let values)? = object[key] else {
      throw MinimalTaskConformanceError.invalidFixture
    }
    return try values.map { value in
      guard
        case .number(let number) = value,
        let result = Int(number.rawToken)
      else {
        throw MinimalTaskConformanceError.invalidFixture
      }
      return result
    }
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
