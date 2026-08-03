import Foundation
import LegadoCore
import LibraryDomain
import ReaderCore

struct ReaderProgressWebDAVConflictConformanceRun: Sendable {
  let artifact: JSONValue
  let requestPlan: JSONValue
}

enum ReaderProgressWebDAVConflictConformanceRunner {
  private struct CloudFixture {
    let positions: [String: ReadingPosition]
    let routeRequestCounts: [JSONValue]
  }

  static let fixtureID =
    "rl-reader-progress-webdav-conflict-runtime-001"

  static func run(
    fixtureDirectory: URL
  ) throws -> ReaderProgressWebDAVConflictConformanceRun {
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

    let cloudFixture = try cloudFixture(
      caseRoot: caseRoot,
      fixtureDirectory: fixtureDirectory
    )
    var identifiers: Set<String> = []
    var plans: [JSONValue] = []
    var cases: [JSONValue] = []
    for value in inputCases {
      guard
        case .object(let inputCase) = value,
        case .string(let id)? = inputCase["id"],
        identifiers.insert(id).inserted,
        inputCase["operation"] == .string("single_book_progress_sync"),
        case .object(let arguments)? = inputCase["arguments"],
        let cloud = cloudFixture.positions[id]
      else {
        throw MinimalTaskConformanceError.invalidFixture
      }
      plans.append(
        .object([
          "operation": .string("single_book_progress_sync"),
          "arguments": .object(arguments),
        ])
      )
      cases.append(
        .object([
          "id": .string(id),
          "operation": .string("single_book_progress_sync"),
          "result": try projection(arguments: arguments, cloud: cloud),
          "issue": .null,
        ])
      )
    }

    guard identifiers == Set(cloudFixture.positions.keys) else {
      throw MinimalTaskConformanceError.invalidFixture
    }
    let requestPlan = JSONValue.array(plans)
    return ReaderProgressWebDAVConflictConformanceRun(
      artifact: .object([
        "schema_version": number(1),
        "fixture_id": .string(fixtureID),
        "engine": .object([
          "platform": .string("ios"),
          "revision": .string("reader-progress-webdav-conflict-v1"),
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
            "source_lab_observation": .object([
              "route_request_counts": .array(
                cloudFixture.routeRequestCounts
              )
            ]),
          ]),
        ]),
        "issues": .array([]),
      ]),
      requestPlan: requestPlan
    )
  }

  private static func projection(
    arguments: [String: JSONValue],
    cloud: ReadingPosition
  ) throws -> JSONValue {
    let local = ReadingPosition(
      chapterIndex: try integer("local_chapter_index", arguments),
      characterOffset: try integer("local_chapter_pos", arguments)
    )
    let confirmRollback = try boolean("confirm_rollback", arguments)
    let result = AndroidReaderProgressSyncPolicy.resolve(
      local: local,
      cloud: cloud,
      confirmRollback: confirmRollback
    )
    return .object([
      "local_chapter_index": number(local.chapterIndex),
      "local_char_position": number(local.characterOffset),
      "before_confirmation_chapter_index": number(
        result.beforeConfirmation.chapterIndex
      ),
      "before_confirmation_char_position": number(
        result.beforeConfirmation.characterOffset
      ),
      "confirmation_requested": .bool(result.confirmationRequested),
      "confirmation_accepted": .bool(result.confirmationAccepted),
      "final_chapter_index": number(result.final.chapterIndex),
      "final_char_position": number(result.final.characterOffset),
    ])
  }

  private static func cloudFixture(
    caseRoot: [String: JSONValue],
    fixtureDirectory: URL
  ) throws -> CloudFixture {
    guard
      case .object(let transport)? = caseRoot["transport"],
      transport["external_network"] == .string("deny"),
      case .array(let responses)? = transport["responses"]
    else {
      throw MinimalTaskConformanceError.invalidFixture
    }
    var values: [String: ReadingPosition] = [:]
    var routeIdentifiers: Set<String> = []
    var routeRequestCounts: [JSONValue] = []
    for response in responses {
      guard
        case .object(let route) = response,
        case .string(let routeID)? = route["id"],
        routeIdentifiers.insert(routeID).inserted,
        case .object(let match)? = route["match"],
        match["method"] == .string("GET"),
        case .string(let path)? = match["path"],
        case .object(let respond)? = route["respond"],
        respond["status"] == number(200),
        case .string(let bodyFile)? = respond["body_file"],
        bodyFile.hasPrefix("responses/"),
        !bodyFile.contains("..")
      else {
        throw MinimalTaskConformanceError.invalidFixture
      }
      let components = path.split(separator: "/").map(String.init)
      guard
        components.count == 5,
        components[0] == "dav",
        components[2] == "legado",
        components[3] == "bookProgress",
        components[4] == "SyncBook_SyncAuthor.json"
      else {
        throw MinimalTaskConformanceError.invalidFixture
      }
      let caseID = components[1]
      let payload = try json(
        at: fixtureDirectory.appendingPathComponent(bodyFile)
      )
      guard
        case .object(let object) = payload,
        object["name"] == .string("SyncBook"),
        object["author"] == .string("SyncAuthor")
      else {
        throw MinimalTaskConformanceError.invalidFixture
      }
      let position = ReadingPosition(
        chapterIndex: try integer("durChapterIndex", object),
        characterOffset: try integer("durChapterPos", object)
      )
      guard values.updateValue(position, forKey: caseID) == nil else {
        throw MinimalTaskConformanceError.invalidFixture
      }
      routeRequestCounts.append(
        .object([
          "request_count": number(1),
          "route_id": .string(routeID),
        ])
      )
    }
    return CloudFixture(
      positions: values,
      routeRequestCounts: routeRequestCounts
    )
  }

  private static func integer(
    _ key: String,
    _ values: [String: JSONValue]
  ) throws -> Int {
    guard
      case .number(let value)? = values[key],
      let integer = Int(value.rawToken)
    else {
      throw MinimalTaskConformanceError.invalidFixture
    }
    return integer
  }

  private static func boolean(
    _ key: String,
    _ values: [String: JSONValue]
  ) throws -> Bool {
    guard case .bool(let value)? = values[key] else {
      throw MinimalTaskConformanceError.invalidFixture
    }
    return value
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

  private static func number(_ value: Int) -> JSONValue {
    .number(JSONNumber(Int64(value)))
  }
}
