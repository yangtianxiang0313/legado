import Foundation
import LegadoCore
import LibraryDomain

struct BookDetailStagingConformanceRun: Sendable {
  let artifact: JSONValue
  let requestPlan: JSONValue
}

enum BookDetailStagingConformanceRunner {
  static let fixtureID = "rl-library-book-detail-staging-runtime-001"

  static func run(
    fixtureDirectory: URL
  ) throws -> BookDetailStagingConformanceRun {
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
        case .string(let operation)? = inputCase["operation"],
        case .object(let arguments)? = inputCase["arguments"]
      else {
        throw MinimalTaskConformanceError.invalidFixture
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
          "result": try execute(operation: operation, arguments: arguments),
          "issue": .null,
        ])
      )
    }

    return BookDetailStagingConformanceRun(
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

  static func execute(
    operation: String,
    arguments: [String: JSONValue]
  ) throws -> JSONValue {
    let chapterCount = Int(try integer("chapter_count", in: arguments))
    let bookID = LibraryDomain.BookID(rawValue: "fixture-book")
    let candidate = LibraryBook(
      id: bookID,
      title: "Fixture Book",
      author: "Fixture Author"
    )
    let seedExistingProgress = boolean(
      "seed_existing_progress",
      in: arguments,
      default: false
    )
    let priorBook = seedExistingProgress
      ? LibraryBook(
        id: bookID,
        title: "Prior Book",
        author: "Fixture Author",
        progress: BookReadingProgress(chapterIndex: 3, chapterPosition: 19),
        order: 100,
        membership: .member(groupID: 1)
      )
      : nil
    var state = BookDetailStagingState(
      priorBook: priorBook,
      previousMinimumOrder: seedExistingProgress ? 100 : nil
    )

    switch operation {
    case "detail_candidate_save":
      state.saveCandidate(candidate)
    case "detail_explicit_add":
      state.explicitlyAdd(candidate, chapterCount: chapterCount)
    case "detail_toc_stage":
      state.stageTableOfContents(candidate, chapterCount: chapterCount)
    case "detail_group_selection":
      state = BookDetailStagingState()
      state.selectGroup(
        Int(try integer("group_id", in: arguments)),
        candidate: candidate,
        chapterCount: chapterCount
      )
    case "reader_discard_staged":
      state.stageTableOfContents(candidate, chapterCount: chapterCount)
      state.discardFromReaderIfStaged()
    default:
      throw MinimalTaskConformanceError.invalidFixture
    }

    let observation = state.observation
    return .object([
      "book_persisted": .bool(observation.bookPersisted),
      "chapter_count": .number(JSONNumber(Int64(observation.chapterCount))),
      "copied_progress": .bool(observation.copiedProgress),
      "group": .number(JSONNumber(Int64(observation.groupID))),
      "in_bookshelf": .bool(observation.inBookshelf),
      "order_before_previous_minimum":
        .bool(observation.orderBeforePreviousMinimum),
    ])
  }

  private static func integer(
    _ key: String,
    in object: [String: JSONValue]
  ) throws -> Int64 {
    guard
      case .number(let number)? = object[key],
      let value = Int64(number.rawToken)
    else {
      throw MinimalTaskConformanceError.invalidFixture
    }
    return value
  }

  private static func boolean(
    _ key: String,
    in object: [String: JSONValue],
    default defaultValue: Bool
  ) -> Bool {
    guard case .bool(let value)? = object[key] else {
      return defaultValue
    }
    return value
  }
}
