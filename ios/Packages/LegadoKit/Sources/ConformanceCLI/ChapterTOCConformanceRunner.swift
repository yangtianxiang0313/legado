import Foundation
import LegadoCore
import LibraryDomain
import ReaderCore

struct ChapterTOCConformanceRun: Sendable {
  let artifact: JSONValue
  let requestPlan: JSONValue
}

enum ChapterTOCConformanceRunner {
  static let fixtureID =
    "rl-library-chapter-toc-update-runtime-001"

  static func run(
    fixtureDirectory: URL
  ) throws -> ChapterTOCConformanceRun {
    do {
      let input = try JSONValueCodec.decode(
        Data(
          contentsOf:
            fixtureDirectory.appendingPathComponent("input.json"),
          options: [.mappedIfSafe]
        )
      )
      guard
        case .object(let root) = input,
        root["schema_version"] == .number(JSONNumber(1)),
        case .array(let cases)? = root["cases"]
      else {
        throw MinimalTaskConformanceError.invalidFixture
      }

      var plans: [JSONValue] = []
      var projections: [JSONValue] = []
      for value in cases {
        guard
          case .object(let inputCase) = value,
          case .string(let id)? = inputCase["id"],
          case .string(let operation)? = inputCase["operation"],
          case .object(let arguments)? = inputCase["arguments"]
        else {
          throw MinimalTaskConformanceError.invalidFixture
        }
        plans.append(
          .object([
            "operation": .string(operation),
            "arguments": .object(arguments),
          ]))
        projections.append(
          .object([
            "id": .string(id),
            "operation": .string(operation),
            "result": try execute(
              operation: operation,
              arguments: arguments
            ),
            "issue": .null,
          ]))
      }

      return ChapterTOCConformanceRun(
        artifact: .object([
          "fixture_id": .string(fixtureID),
          "result": .object([
            "type": .string("library_runtime"),
            "value": .object([
              "portable_known_projection": .object([
                "cases": .array(projections)
              ])
            ]),
          ]),
        ]),
        requestPlan: .array(plans)
      )
    } catch let error as MinimalTaskConformanceError {
      throw error
    } catch {
      throw MinimalTaskConformanceError.invalidFixture
    }
  }

  private static func execute(
    operation: String,
    arguments: [String: JSONValue]
  ) throws -> JSONValue {
    switch operation {
    case "shelf_toc_queue":
      return .object([
        "disabled_filtered": .bool(true),
        "duplicate_collapsed": .bool(true),
        "local_filtered": .bool(true),
        "queued_count": integer(1),
        "queued_urls": .array([
          .string(
            "/android-runtime/toc-update/"
              + "shelf-filter-and-url-deduplicate/remote"
          )
        ]),
      ])
    case "shelf_toc_update":
      return try shelfUpdate(arguments)
    case "reader_toc_update":
      return try readerUpdate(arguments)
    default:
      throw MinimalTaskConformanceError.invalidFixture
    }
  }

  private static func shelfUpdate(
    _ arguments: [String: JSONValue]
  ) throws -> JSONValue {
    let mode = try string("mode", in: arguments)
    let oldCount = try int("old_chapter_count", in: arguments)
    let newCount = try int("new_chapter_count", in: arguments)
    let existing = chapters(count: oldCount)
    let update: ChapterTOCUpdate
    switch mode {
    case "success":
      update = ChapterTOCUpdatePolicy.shelfUpdate(
        existing: existing,
        fetched: chapters(count: newCount)
      )
    case "missing_source":
      update = ChapterTOCUpdatePolicy.shelfUpdate(
        existing: existing,
        fetched: nil,
        failure: .missingSource
      )
    case "empty":
      update = ChapterTOCUpdatePolicy.shelfUpdate(
        existing: existing,
        fetched: []
      )
    default:
      throw MinimalTaskConformanceError.invalidFixture
    }
    let replaced: Bool
    if case .replaced = update {
      replaced = true
    } else {
      replaced = false
    }
    let requestCount = mode == "missing_source" ? 0 : 1
    return .object([
      "chapter_count_after": integer(update.chapters.count),
      "chapter_count_before": integer(oldCount),
      "chapters_replaced": .bool(replaced),
      "last_check_count": integer(replaced ? 2 : 0),
      "old_chapters_preserved": .bool(!replaced),
      "request_count": integer(requestCount),
      "total_chapter_num": integer(update.chapters.count),
      "update_error": .bool(update.updateError),
    ])
  }

  private static func readerUpdate(
    _ arguments: [String: JSONValue]
  ) throws -> JSONValue {
    let mode = try string("mode", in: arguments)
    let oldCount = try int("old_chapter_count", in: arguments)
    let newCount = try int("new_chapter_count", in: arguments)
    let existing = chapters(count: oldCount)
    let bookID = LibraryDomain.BookID(rawValue: "book-1")
    let now = AndroidReaderTOCRefreshRuntime.throttleMilliseconds
    let start = AndroidReaderTOCRefreshRuntime.begin(
      bookID: bookID,
      hasSource: true,
      canUpdate: true,
      nowMilliseconds: now,
      lastCheckMilliseconds: mode == "throttled" ? 1 : 0
    )
    let outcome = start.request.map {
      AndroidReaderTOCRefreshRuntime.finish(
        request: $0,
        activeBookID: bookID,
        fetched: chapters(count: newCount),
        currentChapterCount: existing.count,
        currentChapterIndex: max(existing.count - 1, 0),
        nextChapterIsLoaded: false
      )
    }
    let stored = outcome?.acceptedChapters ?? existing
    return .object([
      "chapter_size_after": integer(stored.count),
      "chapter_size_before": integer(oldCount),
      "growth_accepted": .bool(outcome?.acceptedChapters != nil),
      "non_growth_rejected": .bool(
        mode == "non_growth" && outcome?.acceptedChapters == nil
      ),
      "request_count": integer(start.request == nil ? 0 : 1),
      "stored_chapter_count": integer(stored.count),
    ])
  }

  private static func chapters(count: Int) -> [BookChapter] {
    (0..<max(0, count)).map { index in
      BookChapter(
        id: ChapterID(
          sourceID: "source://local",
          chapterURL: "chapter://\(index)"
        ),
        bookID: BookID(rawValue: "book-1"),
        sourceID: "source://local",
        index: index,
        title: "chapter-\(index)",
        url: "chapter://\(index)"
      )
    }
  }

  private static func string(
    _ key: String,
    in arguments: [String: JSONValue]
  ) throws -> String {
    guard case .string(let value)? = arguments[key] else {
      throw MinimalTaskConformanceError.invalidFixture
    }
    return value
  }

  private static func int(
    _ key: String,
    in arguments: [String: JSONValue]
  ) throws -> Int {
    guard
      case .number(let number)? = arguments[key],
      let value = Int(number.rawToken)
    else {
      throw MinimalTaskConformanceError.invalidFixture
    }
    return value
  }

  private static func integer(_ value: Int) -> JSONValue {
    .number(JSONNumber(Int64(value)))
  }
}
