import Foundation
import LegadoCore
import SourceRuntime

struct SourceJSONPathRegexConformanceRun: Sendable {
  let artifact: JSONValue
  let requestPlan: JSONValue
}

enum SourceJSONPathRegexConformanceRunner {
  static let fixtureID =
    "sl-source-rule-jsonpath-regex-backends-001"

  static func run(
    fixtureDirectory: URL
  ) throws -> SourceJSONPathRegexConformanceRun {
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
        inputCase["operation"] == .string("jsonpath_regex_backends"),
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
          "operation": .string("jsonpath_regex_backends"),
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
    return SourceJSONPathRegexConformanceRun(
      artifact: artifact,
      requestPlan: canonicalPlans
    )
  }

  private static func projection(
    _ arguments: [String: JSONValue]
  ) throws -> JSONValue {
    switch try string("mode", in: arguments) {
    case "jsonpath_matrix":
      return try jsonPathMatrix(
        arguments,
        evaluator: SourceJSONPathEvaluator(
          input: .jsonString(try string("content", in: arguments))
        )
      )
    case "jsonpath_object_input":
      guard let object = arguments["content_object"] else {
        throw SourcePipelineConformanceError.invalidSourceDefinition
      }
      return try jsonPathMatrix(
        arguments,
        evaluator: SourceJSONPathEvaluator(input: .object(object))
      )
    case "jsonpath_failure":
      return try jsonPathFailure(arguments)
    case "regex_capture":
      return try regexCapture(arguments)
    case "regex_replacement":
      return try regexReplacement(arguments)
    case "regex_failure":
      return try regexFailure(arguments)
    default:
      throw SourcePipelineConformanceError.invalidSourceDefinition
    }
  }

  private static func jsonPathMatrix(
    _ arguments: [String: JSONValue],
    evaluator: SourceJSONPathEvaluator
  ) throws -> JSONValue {
    let rules = try object("rules", in: arguments)
    var result: [String: JSONValue] = [:]
    for label in rules.keys.sorted() {
      result[label] = jsonPathConsumers(
        evaluator,
        rule: try string(label, in: rules)
      )
    }
    return .object(result)
  }

  private static func jsonPathFailure(
    _ arguments: [String: JSONValue]
  ) throws -> JSONValue {
    let evaluator = try SourceJSONPathEvaluator(
      input: .jsonString(try string("content", in: arguments))
    )
    return .object([
      "missing": jsonPathConsumers(
        evaluator,
        rule: try string("missing_rule", in: arguments)
      ),
      "null": jsonPathConsumers(
        evaluator,
        rule: try string("null_rule", in: arguments)
      ),
      "malformed": jsonPathConsumers(
        evaluator,
        rule: try string("malformed_rule", in: arguments)
      ),
    ])
  }

  private static func jsonPathConsumers(
    _ evaluator: SourceJSONPathEvaluator,
    rule: String
  ) -> JSONValue {
    .object([
      "string": attempt {
        .string(evaluator.getString(rule))
      },
      "list": attempt {
        .array(evaluator.getStringList(rule).map(JSONValue.string))
      },
      "element": attempt {
        try evaluator.getElement(rule)
      },
      "elements": attempt {
        .array(evaluator.getElements(rule))
      },
    ])
  }

  private static func regexCapture(
    _ arguments: [String: JSONValue]
  ) throws -> JSONValue {
    let content = try string("content", in: arguments)
    let rules = try object("rules", in: arguments)
    let evaluator = SourceRegexEvaluator()
    var result: [String: JSONValue] = [:]
    for label in rules.keys.sorted() {
      let rule = try string(label, in: rules)
      result[label] = .object([
        "element": attempt {
          guard
            let value = try evaluator.getElement(
              content: content,
              rule: rule
            )
          else {
            return .null
          }
          return .array(value.map(JSONValue.string))
        },
        "elements": attempt {
          .array(
            try evaluator.getElements(content: content, rule: rule)
              .map { .array($0.map(JSONValue.string)) }
          )
        },
      ])
    }
    return .object(result)
  }

  private static func regexReplacement(
    _ arguments: [String: JSONValue]
  ) throws -> JSONValue {
    let evaluator = SourceRegexReplacementEvaluator(
      content: try string("content", in: arguments)
    )
    let rules = try object("rules", in: arguments)
    var result: [String: JSONValue] = [:]
    for label in rules.keys.sorted() {
      let rule = try string(label, in: rules)
      result[label] = .object([
        "string": attempt {
          .string(evaluator.getString(rule))
        },
        "list": attempt {
          .array(evaluator.getStringList(rule).map(JSONValue.string))
        },
      ])
    }
    return .object(result)
  }

  private static func regexFailure(
    _ arguments: [String: JSONValue]
  ) throws -> JSONValue {
    let content = try string("content", in: arguments)
    let replacement = SourceRegexReplacementEvaluator(content: content)
    let captures = SourceRegexEvaluator()
    let malformed = try string("malformed_capture_rule", in: arguments)
    let optional = try string("optional_single_rule", in: arguments)
    return .object([
      "invalid_replace_all": attempt {
        .string(
          replacement.getString(
            try string("invalid_replace_all_rule", in: arguments)
          )
        )
      },
      "invalid_replace_first": attempt {
        .string(
          replacement.getString(
            try string("invalid_replace_first_rule", in: arguments)
          )
        )
      },
      "malformed_capture": .object([
        "element": attempt {
          guard
            let value = try captures.getElement(
              content: content,
              rule: malformed
            )
          else {
            return .null
          }
          return .array(value.map(JSONValue.string))
        },
        "elements": attempt {
          .array(
            try captures.getElements(content: content, rule: malformed)
              .map { .array($0.map(JSONValue.string)) }
          )
        },
      ]),
      "optional_single": attempt {
        guard
          let value = try captures.getElement(
            content: content,
            rule: optional
          )
        else {
          return .null
        }
        return .array(value.map(JSONValue.string))
      },
    ])
  }

  private static func attempt(
    _ operation: () throws -> JSONValue
  ) -> JSONValue {
    do {
      return .object([
        "completed": .bool(true),
        "exception_type": .null,
        "value": try operation(),
      ])
    } catch {
      return .object([
        "completed": .bool(false),
        "exception_type": .string(exceptionType(error)),
        "value": .null,
      ])
    }
  }

  private static func exceptionType(_ error: Error) -> String {
    switch error {
    case SourceJSONPathBackendError.pathNotFound:
      "com.jayway.jsonpath.PathNotFoundException"
    case SourceJSONPathBackendError.invalidPath:
      "com.jayway.jsonpath.InvalidPathException"
    case SourceJSONPathBackendError.nullElement:
      "java.lang.NullPointerException"
    case SourceJSONPathBackendError.malformedInput:
      "com.alibaba.fastjson.JSONException"
    case SourceRegexBackendError.invalidPattern:
      "java.util.regex.PatternSyntaxException"
    case SourceRegexBackendError.unmatchedGroup:
      "java.lang.NullPointerException"
    default:
      "unexpected"
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

  private static func object(
    _ key: String,
    in object: [String: JSONValue]
  ) throws -> [String: JSONValue] {
    guard case .object(let value)? = object[key] else {
      throw SourcePipelineConformanceError.invalidSourceDefinition
    }
    return value
  }

  private static func json(at url: URL) throws -> JSONValue {
    do {
      return try JSONValueCodec.decode(Data(contentsOf: url))
    } catch {
      throw SourcePipelineConformanceError.invalidSourceDefinition
    }
  }
}
