import Foundation
import LegadoCore
import LibraryDomain

struct SearchBookLifecycleConformanceRun: Sendable {
  let artifact: JSONValue
  let requestPlan: JSONValue
}

enum SearchBookLifecycleConformanceRunner {
  static let fixtureID =
    "rl-discovery-search-book-persistence-lifecycle-001"

  static func run(
    fixtureDirectory: URL
  ) throws -> SearchBookLifecycleConformanceRun {
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
          ])
        )
        let result = try execute(
          operation: operation,
          arguments: arguments
        )
        projections.append(
          .object([
            "id": .string(id),
            "operation": .string(operation),
            "result": result,
            "issue": .null,
          ])
        )
      }

      return SearchBookLifecycleConformanceRun(
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
    case "search_book_merge":
      return try merge(arguments)
    case "search_book_room_replace":
      return try replace(arguments)
    case "search_book_source_cascade":
      return try cascade(arguments)
    case "search_book_ttl_cleanup":
      return try cleanup(arguments)
    default:
      throw MinimalTaskConformanceError.invalidFixture
    }
  }

  private static func merge(
    _ arguments: [String: JSONValue]
  ) throws -> JSONValue {
    guard
      case .string(let keyword)? = arguments["keyword"],
      case .bool(let precision)? = arguments["precision"],
      case .array(let rawBatches)? = arguments["batches"]
    else {
      throw MinimalTaskConformanceError.invalidFixture
    }
    let batches = try rawBatches.map { value -> [SearchBookCandidate] in
      guard case .array(let candidates) = value else {
        throw MinimalTaskConformanceError.invalidFixture
      }
      return try candidates.map(candidate)
    }
    let books = SearchBookSearchState.aggregate(
      batches: batches,
      keyword: keyword,
      precision: precision
    )
    return .object([
      "books": .array(
        books.map { book in
          .object([
            "name": .string(book.representative.name),
            "author": .string(book.representative.author),
            "book_url": .string(book.representative.bookURL),
            "representative_origin":
              .string(book.representative.origin),
            "origin_order":
              .number(JSONNumber(Int64(book.representative.originOrder))),
            "origins": .array(book.origins.map(JSONValue.string)),
          ])
        }
      ),
      "count": .number(JSONNumber(Int64(books.count))),
    ])
  }

  private static func replace(
    _ arguments: [String: JSONValue]
  ) throws -> JSONValue {
    let bookURL = try string("book_url", in: arguments)
    let origin = try string("origin", in: arguments)
    let firstName = try string("first_name", in: arguments)
    let secondName = try string("second_name", in: arguments)
    var store = SearchBookCandidateStore(sourceIDs: [origin])
    let first = store.insert(
      SearchBookCandidate(
        name: firstName,
        author: "",
        bookURL: bookURL,
        origin: origin
      )
    )
    let second = store.insert(
      SearchBookCandidate(
        name: secondName,
        author: "",
        bookURL: bookURL,
        origin: origin
      )
    )
    guard let stored = store.candidate(bookURL: bookURL) else {
      throw MinimalTaskConformanceError.invalidFixture
    }
    return .object([
      "insert_results": .array([
        .number(JSONNumber(first.sequence)),
        .number(JSONNumber(second.sequence)),
      ]),
      "stored_name": .string(stored.name),
      "stored_origin": .string(stored.origin),
    ])
  }

  private static func cascade(
    _ arguments: [String: JSONValue]
  ) throws -> JSONValue {
    let bookURL = try string("book_url", in: arguments)
    let origin = try string("origin", in: arguments)
    var store = SearchBookCandidateStore(sourceIDs: [origin])
    store.insert(
      SearchBookCandidate(
        name: "",
        author: "",
        bookURL: bookURL,
        origin: origin
      )
    )
    let before = store.candidate(bookURL: bookURL) != nil
    store.removeSource(origin)
    return .object([
      "exists_before_source_delete": .bool(before),
      "exists_after_source_delete":
        .bool(store.candidate(bookURL: bookURL) != nil),
    ])
  }

  private static func cleanup(
    _ arguments: [String: JSONValue]
  ) throws -> JSONValue {
    let origin = try string("origin", in: arguments)
    let threshold = try integer("threshold", in: arguments)
    let values = [
      ("stale", try integer("stale_time", in: arguments)),
      ("boundary", try integer("boundary_time", in: arguments)),
      ("fresh", try integer("fresh_time", in: arguments)),
    ]
    var store = SearchBookCandidateStore(sourceIDs: [origin])
    for (name, time) in values {
      store.insert(
        SearchBookCandidate(
          name: name,
          author: "",
          bookURL: name,
          origin: origin,
          observedAt: time
        )
      )
    }
    store.clearExpired(earlierThan: threshold)
    return .object([
      "remaining": .array(
        store.candidates.map { .string($0.bookURL) }
      ),
      "threshold": .number(JSONNumber(threshold)),
    ])
  }

  private static func candidate(
    _ value: JSONValue
  ) throws -> SearchBookCandidate {
    guard case .object(let object) = value else {
      throw MinimalTaskConformanceError.invalidFixture
    }
    return SearchBookCandidate(
      name: try string("name", in: object),
      author: try string("author", in: object),
      bookURL: try string("book_url", in: object),
      origin: try string("origin", in: object),
      originOrder: Int(try integer("origin_order", in: object))
    )
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
  ) throws -> Int64 {
    guard
      case .number(let number)? = object[key],
      let value = Int64(number.rawToken)
    else {
      throw MinimalTaskConformanceError.invalidFixture
    }
    return value
  }
}
