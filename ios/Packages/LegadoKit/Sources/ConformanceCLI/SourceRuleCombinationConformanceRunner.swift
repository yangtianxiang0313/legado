import Foundation
import LegadoCore
import SourceRuntime

struct SourceRuleCombinationConformanceRun: Sendable {
  let artifact: JSONValue
  let requestPlan: JSONValue
}

enum SourceRuleCombinationConformanceRunner {
  static let fixtureID =
    "sl-source-rule-combination-and-coercion-runtime-001"

  static func run(
    fixtureDirectory: URL
  ) throws -> SourceRuleCombinationConformanceRun {
    let caseDocument = try json(
      at: fixtureDirectory.appendingPathComponent("case.json")
    )
    let inputDocument = try json(
      at: fixtureDirectory.appendingPathComponent("input.json")
    )
    guard
      case .object(let caseRoot) = caseDocument,
      caseRoot["id"] == .string(fixtureID),
      case .object(let determinism)? = caseRoot["determinism"],
      case .string(let origin)? = determinism["logical_origin"],
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
        inputCase["operation"] == .string("rule_combination_coercion"),
        case .object(let arguments)? = inputCase["arguments"],
        case .object(let request)? = inputCase["request"],
        request["method"] == .string("GET"),
        case .string(let target)? = request["target"],
        target.hasPrefix("/")
      else {
        throw SourcePipelineConformanceError.invalidSourceDefinition
      }
      plans.append(requestPlanValue(url: origin + target))
      cases.append(
        .object([
          "id": .string(id),
          "operation": .string("rule_combination_coercion"),
          "result": try projection(arguments),
          "issue": .null,
        ])
      )
    }

    let canonicalPlans = JSONValue.array(plans)
    let artifact = JSONValue.object([
      "schema_version": .number(JSONNumber(1)),
      "fixture_id": .string(fixtureID),
      "engine": .object([
        "platform": .string("ios"),
        "revision": .string("conformance-source-runtime-v2"),
        "compatibility_profile": .string("android-legado-v1"),
      ]),
      "request_plan": canonicalPlans,
      "decode": .null,
      "stages": .array([]),
      "result": .object([
        "type": .string("source_pipeline"),
        "value": .object([
          "portable_known_projection": .object([
            "cases": .array(cases)
          ])
        ]),
      ]),
      "issues": .array([]),
    ])
    return SourceRuleCombinationConformanceRun(
      artifact: artifact,
      requestPlan: canonicalPlans
    )
  }

  private static func projection(
    _ arguments: [String: JSONValue]
  ) throws -> JSONValue {
    switch try string("mode", in: arguments) {
    case "string_and_list":
      return try stringAndList(arguments)
    case "scalar_matrix":
      return try scalarMatrix(arguments)
    case "element_matrix":
      return try elementMatrix(arguments)
    case "sequential_chain":
      return try sequentialChain(arguments)
    case "url_list":
      return try urlList(arguments)
    case "empty_matrix":
      return try emptyMatrix(arguments)
    case "exception_boundary":
      return exceptionBoundary(arguments)
    default:
      throw SourcePipelineConformanceError.invalidSourceDefinition
    }
  }

  private static func stringAndList(
    _ arguments: [String: JSONValue]
  ) throws -> JSONValue {
    let evaluator = try evaluator(arguments)
    let rule = try string("rule", in: arguments)
    return .object([
      "string": .string(try evaluator.getString(rule)),
      "list": stringList(try evaluator.getStringList(rule)),
    ])
  }

  private static func scalarMatrix(
    _ arguments: [String: JSONValue]
  ) throws -> JSONValue {
    let evaluator = try evaluator(arguments)
    guard case .object(let rules)? = arguments["rules"] else {
      throw SourcePipelineConformanceError.invalidSourceDefinition
    }
    let values = try ["number", "boolean", "null", "string"].map {
      label -> JSONValue in
      let rule = try string(label, in: rules)
      return .object([
        "label": .string(label),
        "string": .string(try evaluator.getString(rule)),
        "list": stringList(try evaluator.getStringList(rule)),
      ])
    }
    return .object(["values": .array(values)])
  }

  private static func elementMatrix(
    _ arguments: [String: JSONValue]
  ) throws -> JSONValue {
    let evaluator = try evaluator(arguments)
    let object = try evaluator.getElement(
      string("object_rule", in: arguments)
    )
    let elements = try evaluator.getElements(
      string("elements_rule", in: arguments)
    )
    let scalar = try evaluator.getElement(
      string("scalar_rule", in: arguments)
    )
    return .object([
      "object_type": runtimeType(object),
      "object_json": .string(gsonJSON(object ?? .null)),
      "elements_count": .number(JSONNumber(Int64(elements.count))),
      "elements_json": .string(gsonJSON(.array(elements))),
      "scalar_type": runtimeType(scalar),
      "scalar_json": .string(gsonJSON(scalar ?? .null)),
    ])
  }

  private static func sequentialChain(
    _ arguments: [String: JSONValue]
  ) throws -> JSONValue {
    let evaluator = try evaluator(arguments)
    return .object([
      "string": .string(
        try evaluator.getString(string("string_rule", in: arguments))
      ),
      "list": stringList(
        try evaluator.getStringList(string("list_rule", in: arguments))
      ),
    ])
  }

  private static func urlList(
    _ arguments: [String: JSONValue]
  ) throws -> JSONValue {
    let evaluator = try evaluator(arguments)
    guard
      let redirectURL = URL(
        string: try string("redirect_url", in: arguments)
      )
    else {
      throw SourcePipelineConformanceError.invalidSourceDefinition
    }
    return .object([
      "urls": stringList(
        try evaluator.getStringList(
          string("rule", in: arguments),
          isURL: true,
          redirectURL: redirectURL
        )
      )
    ])
  }

  private static func emptyMatrix(
    _ arguments: [String: JSONValue]
  ) throws -> JSONValue {
    let evaluator = try evaluator(arguments)
    let missing = try string("missing_rule", in: arguments)
    return .object([
      "empty_string": .string(try evaluator.getString(nil)),
      "empty_list": stringList(try evaluator.getStringList(nil)),
      "empty_element": element(try evaluator.getElement("")),
      "empty_elements_count": .number(
        JSONNumber(Int64(try evaluator.getElements("").count))
      ),
      "missing_string": .string(try evaluator.getString(missing)),
      "missing_list": stringList(try evaluator.getStringList(missing)),
    ])
  }

  private static func exceptionBoundary(
    _ arguments: [String: JSONValue]
  ) -> JSONValue {
    do {
      let evaluator = try evaluator(arguments)
      let value = try evaluator.getString(string("rule", in: arguments))
      return .object([
        "completed": .bool(true),
        "value": .string(value),
        "exception_type": .null,
      ])
    } catch SourceRuleRuntimeError.scriptFailure {
      return .object([
        "completed": .bool(false),
        "value": .null,
        "exception_type": .string("com.script.ScriptException"),
      ])
    } catch {
      return .object([
        "completed": .bool(false),
        "value": .null,
        "exception_type": .string("unexpected"),
      ])
    }
  }

  private static func evaluator(
    _ arguments: [String: JSONValue]
  ) throws -> SourceRuleConsumerEvaluator {
    SourceRuleConsumerEvaluator(
      content: try string("content", in: arguments)
    )
  }

  private static func stringList(_ value: [String]?) -> JSONValue {
    value.map { .array($0.map(JSONValue.string)) } ?? .null
  }

  private static func element(_ value: JSONValue?) -> JSONValue {
    value ?? .null
  }

  private static func runtimeType(_ value: JSONValue?) -> JSONValue {
    switch value {
    case .object:
      .string("java.util.LinkedHashMap")
    case .number(let number):
      .string(
        Int32(number.rawToken) == nil
          ? "java.lang.Long"
          : "java.lang.Integer"
      )
    case .string:
      .string("java.lang.String")
    case .bool:
      .string("java.lang.Boolean")
    case .array:
      .string("java.util.ArrayList")
    case .null, .none:
      .null
    }
  }

  private static func gsonJSON(_ value: JSONValue) -> String {
    gsonJSON(value, indentation: 0)
  }

  private static func gsonJSON(
    _ value: JSONValue,
    indentation: Int
  ) -> String {
    switch value {
    case .null:
      return "null"
    case .bool(let value):
      return value ? "true" : "false"
    case .number(let value):
      return value.rawToken
    case .string(let value):
      return String(
        decoding: try! JSONValueCodec.encode(.string(value)),
        as: UTF8.self
      )
    case .array(let values):
      guard !values.isEmpty else { return "[]" }
      let prefix = String(repeating: " ", count: indentation + 2)
      let body = values.map {
        prefix + gsonJSON($0, indentation: indentation + 2)
      }.joined(separator: ",\n")
      return "[\n\(body)\n\(String(repeating: " ", count: indentation))]"
    case .object(let object):
      guard !object.isEmpty else { return "{}" }
      let prefix = String(repeating: " ", count: indentation + 2)
      let body = object.keys.sorted().map { key in
        let encodedKey = String(
          decoding: try! JSONValueCodec.encode(.string(key)),
          as: UTF8.self
        )
        let child = gsonJSON(
          object[key] ?? .null,
          indentation: indentation + 2
        )
        return "\(prefix)\(encodedKey): \(child)"
      }.joined(separator: ",\n")
      return "{\n\(body)\n\(String(repeating: " ", count: indentation))}"
    }
  }

  private static func requestPlanValue(url: String) -> JSONValue {
    .object([
      "method": .string("GET"),
      "url": .string(url),
      "headers": .array([]),
      "body": .null,
      "timeout_ms": .null,
    ])
  }

  private static func string(
    _ key: String,
    in object: [String: JSONValue]
  ) throws -> String {
    guard case .string(let value)? = object[key] else {
      throw SourcePipelineConformanceError.invalidSourceDefinition
    }
    return value
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
