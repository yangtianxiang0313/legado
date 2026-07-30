import Foundation
import LegadoCore
import LibraryDomain
import ReaderCore

struct BookSourceMigrationConformanceRun: Sendable {
  let artifact: JSONValue
  let requestPlan: JSONValue
}

enum BookSourceMigrationConformanceRunner {
  static let fixtureID =
    "rl-library-book-source-switch-migration-runtime-001"

  static func run(
    fixtureDirectory: URL
  ) throws -> BookSourceMigrationConformanceRun {
    let input = try JSONValueCodec.decode(
      Data(
        contentsOf: fixtureDirectory.appendingPathComponent("input.json"),
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
        case .string(let operation)? = inputCase["operation"]
      else {
        throw MinimalTaskConformanceError.invalidFixture
      }
      let arguments: [String: JSONValue]
      if case .object(let value)? = inputCase["arguments"] {
        arguments = value
      } else {
        arguments = [:]
      }
      plans.append(
        .object([
          "operation": .string(operation),
          "arguments": .object(arguments),
        ])
      )
      projections.append(
        .object([
          "id": .string(id),
          "operation": .string(operation),
          "result": try execute(
            id: id,
            operation: operation,
            arguments: arguments
          ),
          "issue": .null,
        ])
      )
    }
    return BookSourceMigrationConformanceRun(
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
  }

  private static func execute(
    id: String,
    operation: String,
    arguments: [String: JSONValue]
  ) throws -> JSONValue {
    let oldBook = oldBook(id: id)
    var candidate = candidateBook(id: id)
    let chapters = targetChapters(id: id)
    switch operation {
    case "book_source_migrate":
      let result = try AndroidBookSourceMigrationPolicy.migrate(
        oldBook: oldBook,
        candidate: candidate,
        targetChapters: chapters,
        inBookshelf: false
      )
      var projection = migratedBookProjection(
        oldBook: oldBook,
        newBook: result.book
      )
      projection["target_chapter_count"] = number(chapters.count)
      return .object(projection)
    case "book_source_migrate_empty_toc":
      do {
        _ = try AndroidBookSourceMigrationPolicy.migrate(
          oldBook: oldBook,
          candidate: candidate,
          targetChapters: [],
          inBookshelf: false
        )
        throw MinimalTaskConformanceError.comparisonFailed
      } catch BookSourceMigrationError.emptyTargetTableOfContents(
        let remappedIndex
      ) {
        return .object([
          "error": .string("IndexOutOfBoundsException"),
          "target_progress_index": number(remappedIndex),
          "target_progress_position": number(
            candidate.progress?.position.characterOffset ?? 0
          ),
        ])
      }
    case "book_detail_source_switch":
      guard case .bool(let inBookshelf)? = arguments["in_bookshelf"] else {
        throw MinimalTaskConformanceError.invalidFixture
      }
      candidate.hasUpdateError = true
      let result = try AndroidBookSourceMigrationPolicy.migrate(
        oldBook: oldBook,
        candidate: candidate,
        targetChapters: chapters,
        inBookshelf: inBookshelf
      )
      var projection = migratedBookProjection(
        oldBook: oldBook,
        newBook: result.book
      )
      let observation = result.observation
      projection["in_bookshelf"] = .bool(inBookshelf)
      projection["old_book_persisted"] =
        .bool(observation.oldBookPersisted)
      projection["new_book_persisted"] =
        .bool(observation.newBookPersisted)
      projection["old_chapter_count"] =
        number(observation.oldChapterCount)
      projection["new_chapter_count"] =
        number(observation.newChapterCount)
      projection["view_model_chapter_count"] =
        number(observation.visibleChapterCount)
      projection["update_error_removed"] =
        .bool(observation.updateErrorRemoved)
      return .object(projection)
    default:
      throw MinimalTaskConformanceError.invalidFixture
    }
  }

  private static func oldBook(id: String) -> SourceMigrationBook {
    SourceMigrationBook(
      id: BookID(
        rawValue: "/android-runtime/source-migration/\(id)/old"
      ),
      sourceURL: "android-runtime://source-migration-old",
      title: "Oracle Migration Book",
      author: "Oracle Author",
      progress: ReadingProgress(
        position: ReadingPosition(
          chapterIndex: 1,
          characterOffset: 37
        ),
        chapterTitle: "Chapter 1",
        updatedAtMilliseconds: 123_456_789
      ),
      totalChapterCount: 3,
      userState: SourceMigrationUserState(
        groupID: 5,
        order: -7,
        customCoverURL: "cover://custom",
        customIntro: "custom intro",
        customTag: "custom tag",
        canUpdate: false,
        reverseTOC: true
      )
    )
  }

  private static func candidateBook(id: String) -> SourceMigrationBook {
    SourceMigrationBook(
      id: BookID(
        rawValue: "/android-runtime/source-migration/\(id)/new"
      ),
      sourceURL: "android-runtime://source-migration-new",
      title: "Oracle Migration Book",
      author: "Oracle Author",
      totalChapterCount: 3
    )
  }

  private static func targetChapters(
    id: String
  ) -> [SourceMigrationChapter] {
    (0..<3).map { index in
      SourceMigrationChapter(
        id: ChapterID(
          rawValue:
            "/android-runtime/source-migration/\(id)/new/chapter/\(index)"
        ),
        title: "Chapter \(index)",
        index: index
      )
    }
  }

  private static func migratedBookProjection(
    oldBook: SourceMigrationBook,
    newBook: SourceMigrationBook
  ) -> [String: JSONValue] {
    let progress = newBook.progress
    return [
      "source_identity_changed":
        .bool(oldBook.sourceURL != newBook.sourceURL),
      "target_book_url": .string(newBook.id.rawValue),
      "target_origin": .string(newBook.sourceURL),
      "progress_index": number(
        progress?.position.chapterIndex ?? 0
      ),
      "progress_title": .string(progress?.chapterTitle ?? ""),
      "progress_position": number(
        progress?.position.characterOffset ?? 0
      ),
      "progress_time": number(
        progress?.updatedAtMilliseconds ?? 0
      ),
      "group": number(newBook.userState.groupID),
      "order": number(newBook.userState.order),
      "custom_cover": .string(
        newBook.userState.customCoverURL ?? ""
      ),
      "custom_intro": .string(
        newBook.userState.customIntro ?? ""
      ),
      "custom_tag": .string(
        newBook.userState.customTag ?? ""
      ),
      "can_update": .bool(newBook.userState.canUpdate),
      "reverse_toc": .bool(newBook.userState.reverseTOC),
    ]
  }

  private static func number(_ value: Int) -> JSONValue {
    .number(JSONNumber(Int64(value)))
  }

  private static func number(_ value: Int64) -> JSONValue {
    .number(JSONNumber(value))
  }
}
