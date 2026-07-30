import Foundation
import LegadoCore
import TestSupport

struct ReaderTOCHandoffConformanceRun: Sendable {
  let artifact: JSONValue
  let requestPlan: JSONValue
}

enum ReaderTOCHandoffConformanceRunner {
  static let fixtureID = "rl-ui-reader-toc-result-001"

  static func run(
    fixtureDirectory: URL
  ) throws -> ReaderTOCHandoffConformanceRun {
    do {
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
          operation == "toc_result_contract",
          case .object(let arguments)? = inputCase["arguments"]
        else {
          throw MinimalTaskConformanceError.invalidFixture
        }
        plans.append(.object([
          "operation": .string(operation),
          "arguments": .object(arguments),
        ]))
        projections.append(.object([
          "id": .string(id),
          "operation": .string(operation),
          "result": try execute(arguments),
          "issue": .null,
        ]))
      }

      return ReaderTOCHandoffConformanceRun(
        artifact: .object([
          "fixture_id": .string(fixtureID),
          "result": .object([
            "type": .string("ui_runtime"),
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
    _ arguments: [String: JSONValue]
  ) throws -> JSONValue {
    let completion = try string("completion_code", in: arguments)
    let producerName = try string("producer", in: arguments)
    guard [
      "null_intent",
      "empty_intent",
      "chapter",
      "bookmark",
      "reverse",
    ].contains(producerName) else {
      throw MinimalTaskConformanceError.invalidFixture
    }
    let selection = ReaderTOCHandoffFixture.project(
      completion: completion,
      producer: producerName,
      selectedIndex: integer("selected_index", in: arguments),
      currentIndex: integer("current_index", in: arguments),
      characterOffset: integer("chapter_pos", in: arguments)
    )
    guard let selection else {
      return .object([
        "chapter_changed": .null,
        "chapter_index": .null,
        "chapter_pos": .null,
        "detail_progress_write": .null,
        "producer": .string(producerName),
        "reader_open_arguments": .null,
        "result_present": .bool(false),
      ])
    }
    return .object([
      "chapter_changed": .bool(selection.chapterChanged),
      "chapter_index": number(selection.chapterIndex),
      "chapter_pos": number(selection.characterOffset),
      "detail_progress_write": .object([
        "chapter_changed": .bool(selection.chapterChanged),
        "dur_chapter_index": number(selection.chapterIndex),
        "dur_chapter_pos": number(selection.characterOffset),
      ]),
      "producer": .string(producerName),
      "reader_open_arguments": .array([
        number(selection.chapterIndex),
        number(selection.characterOffset),
      ]),
      "result_present": .bool(true),
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
  ) -> Int? {
    guard
      case .number(let value)? = object[key],
      let integer = Int(value.rawToken)
    else {
      return nil
    }
    return integer
  }

  private static func number(_ value: Int) -> JSONValue {
    .number(JSONNumber(Int64(value)))
  }
}
