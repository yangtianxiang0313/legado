import Foundation
import LegadoCore
import TestSupport

struct SourceImportConformanceRun: Sendable {
  let artifact: JSONValue
  let requestPlan: JSONValue
}

enum SourceImportConformanceRunner {
  static let fixtureID = "rl-app-source-import-runtime-001"

  static func run(
    fixtureDirectory: URL
  ) throws -> SourceImportConformanceRun {
    let caseDocument = try json(
      at: fixtureDirectory.appendingPathComponent("case.json")
    )
    let inputDocument = try json(
      at: fixtureDirectory.appendingPathComponent("input.json")
    )
    guard
      case .object(let caseRoot) = caseDocument,
      caseRoot["id"] == .string(fixtureID),
      case .object(let inputRoot) = inputDocument,
      case .array(let inputCases)? = inputRoot["cases"]
    else {
      throw SourcePipelineConformanceError.invalidSourceDefinition
    }

    var plans: [JSONValue] = []
    var cases: [JSONValue] = []
    for value in inputCases {
      guard
        case .object(let inputCase) = value,
        case .string(let id)? = inputCase["id"],
        case .string(let operation)? = inputCase["operation"],
        case .object(let arguments)? = inputCase["arguments"]
      else {
        throw SourcePipelineConformanceError.invalidSourceDefinition
      }
      plans.append(
        .object([
          "operation": .string(operation),
          "arguments": .object(arguments),
        ])
      )
      cases.append(
        .object([
          "id": .string(id),
          "operation": .string(operation),
          "result": try SourceImportFixtureProjection.project(
            operation: operation,
            arguments: arguments
          ),
          "issue": .null,
        ])
      )
    }

    let canonicalPlans = JSONValue.array(plans)
    return SourceImportConformanceRun(
      artifact: .object([
        "schema_version": .number(JSONNumber(1)),
        "fixture_id": .string(fixtureID),
        "engine": .object([
          "platform": .string("ios"),
          "revision": .string("conformance-source-import-v1"),
          "compatibility_profile": .string("android-legado-v1"),
        ]),
        "request_plan": canonicalPlans,
        "decode": .null,
        "stages": .array([]),
        "result": .object([
          "type": .string("ui_runtime"),
          "value": .object([
            "portable_known_projection": .object([
              "cases": .array(cases)
            ])
          ]),
        ]),
        "issues": .array([]),
      ]),
      requestPlan: canonicalPlans
    )
  }

  private static func json(at url: URL) throws -> JSONValue {
    do {
      return try JSONValueCodec.decode(
        Data(contentsOf: url, options: [.mappedIfSafe])
      )
    } catch {
      throw SourcePipelineConformanceError.invalidSourceDefinition
    }
  }
}
