import Foundation
import LegadoCore
import SourceRuntime

struct SourceDOMSelectorConformanceRun: Sendable {
  let artifact: JSONValue
  let requestPlan: JSONValue
}

enum SourceDOMSelectorConformanceRunner {
  static let fixtureID = "sl-source-rule-dom-selector-backends-001"

  static func run(
    fixtureDirectory: URL
  ) throws -> SourceDOMSelectorConformanceRun {
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
        inputCase["operation"] == .string("dom_selector_backends"),
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
          "operation": .string("dom_selector_backends"),
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
    return SourceDOMSelectorConformanceRun(
      artifact: artifact,
      requestPlan: canonicalPlans
    )
  }

  private static func projection(
    _ arguments: [String: JSONValue]
  ) throws -> JSONValue {
    switch try string("mode", in: arguments) {
    case "css_strings":
      return try cssStrings(arguments)
    case "css_indexing":
      return try stringMatrix(
        arguments,
        labels: [
          "children_second",
          "negative_and_first",
          "slice",
          "exclude",
          "reverse",
        ]
      )
    case "css_combinations":
      return try stringMatrix(arguments, labels: ["and", "or", "percent"])
    case "css_url":
      return try cssURL(arguments)
    case "css_failure":
      return try cssFailure(arguments)
    case "xpath_strings":
      return try xpathStrings(arguments)
    case "xpath_nodes":
      return try xpathNodes(arguments)
    case "xpath_fragments":
      return try xpathFragments(arguments)
    case "xpath_namespace_functions":
      return try xpathNamespaceFunctions(arguments)
    case "xpath_failure":
      return try xpathFailure(arguments)
    default:
      throw SourcePipelineConformanceError.invalidSourceDefinition
    }
  }

  private static func cssStrings(
    _ arguments: [String: JSONValue]
  ) throws -> JSONValue {
    try stringMatrix(
      arguments,
      labels: [
        "text", "own_text", "text_nodes", "html", "all", "attribute", "href",
      ]
    )
  }

  private static func stringMatrix(
    _ arguments: [String: JSONValue],
    labels: [String]
  ) throws -> JSONValue {
    let evaluator = try evaluator(arguments)
    let rules = try object("rules", in: arguments)
    return .object(
      Dictionary(
        uniqueKeysWithValues: try labels.map { label in
          let rule = try string(label, in: rules)
          return (
            label,
            .object([
              "string": .string(try evaluator.getString(rule)),
              "list": stringList(try evaluator.getStringList(rule)),
            ])
          )
        }
      )
    )
  }

  private static func cssURL(
    _ arguments: [String: JSONValue]
  ) throws -> JSONValue {
    let evaluator = try evaluator(arguments)
    let rules = try object("rules", in: arguments)
    guard
      let redirectURL = URL(
        string: try string("redirect_url", in: arguments)
      )
    else {
      throw SourcePipelineConformanceError.invalidSourceDefinition
    }
    return .object(
      Dictionary(
        uniqueKeysWithValues: try ["relative", "all_links", "image", "missing"]
          .map { label in
            let rule = try string(label, in: rules)
            return (
              label,
              .object([
                "raw_string": .string(try evaluator.getString(rule)),
                "raw_list": stringList(try evaluator.getStringList(rule)),
                "absolute_string": .string(
                  try evaluator.getString(
                    rule,
                    isURL: true,
                    redirectURL: redirectURL
                  )
                ),
                "absolute_list": stringList(
                  try evaluator.getStringList(
                    rule,
                    isURL: true,
                    redirectURL: redirectURL
                  )
                ),
              ])
            )
          }
      )
    )
  }

  private static func cssFailure(
    _ arguments: [String: JSONValue]
  ) throws -> JSONValue {
    let evaluator = try evaluator(arguments)
    let missingRule = try string("missing_rule", in: arguments)
    let missingElementsRule = try string(
      "missing_elements_rule",
      in: arguments
    )
    let malformedRule = try string("malformed_rule", in: arguments)
    return .object([
      "missing": .object([
        "string": .string(try evaluator.getString(missingRule)),
        "list": stringList(try evaluator.getStringList(missingRule)),
        "elements_count": .number(
          JSONNumber(Int64(try evaluator.getElements(missingElementsRule).count))
        ),
      ]),
      "malformed": .object([
        "string": attempt(
          exception: "java.lang.StringIndexOutOfBoundsException"
        ) {
          .string(try evaluator.getString(malformedRule))
        },
        "list": attempt(
          exception: "java.lang.StringIndexOutOfBoundsException"
        ) {
          stringList(try evaluator.getStringList(malformedRule))
        },
        "elements": attempt(
          exception: "org.jsoup.select.Selector$SelectorParseException"
        ) {
          nodes(try evaluator.getElements(malformedRule))
        },
      ]),
    ])
  }

  private static func xpathStrings(
    _ arguments: [String: JSONValue]
  ) throws -> JSONValue {
    let evaluator = try evaluator(arguments)
    let rules = try object("rules", in: arguments)
    return .object(
      Dictionary(
        uniqueKeysWithValues: try [
          "text_nodes", "attribute_nodes", "string_function",
          "normalize_function",
        ].map { label in
          let rule = try string(label, in: rules)
          return (label, xpathStringAndList(evaluator, rule: rule))
        }
      )
    )
  }

  private static func xpathNodes(
    _ arguments: [String: JSONValue]
  ) throws -> JSONValue {
    let evaluator = try evaluator(arguments)
    let rules = try object("rules", in: arguments)
    return .object(
      Dictionary(
        uniqueKeysWithValues: try [
          "elements", "text_nodes", "attribute_nodes",
        ].map { label in
          let rule = try string(label, in: rules)
          return (label, nodes(try evaluator.getElements(rule)))
        }
      )
    )
  }

  private static func xpathFragments(
    _ arguments: [String: JSONValue]
  ) throws -> JSONValue {
    let rules = try object("rules", in: arguments)
    let mappings = [
      ("td", "td_fragment"),
      ("tr", "tr_fragment"),
      ("malformed", "malformed_html"),
    ]
    return .object(
      Dictionary(
        uniqueKeysWithValues: try mappings.map { label, contentKey in
          let evaluator = SourceDOMSelectorEvaluator(
            content: try string(contentKey, in: arguments)
          )
          let rule = try string(label, in: rules)
          return (
            label,
            .object([
              "string": .string(try evaluator.getString(rule)),
              "list": stringList(try evaluator.getStringList(rule)),
            ])
          )
        }
      )
    )
  }

  private static func xpathNamespaceFunctions(
    _ arguments: [String: JSONValue]
  ) throws -> JSONValue {
    let evaluator = try evaluator(arguments)
    let rules = try object("rules", in: arguments)
    return .object(
      Dictionary(
        uniqueKeysWithValues: try [
          "local_name_titles", "count", "normalized_first", "namespace_uri",
          "prefixed",
        ].map { label in
          let rule = try string(label, in: rules)
          return (label, xpathStringAndList(evaluator, rule: rule))
        }
      )
    )
  }

  private static func xpathFailure(
    _ arguments: [String: JSONValue]
  ) throws -> JSONValue {
    let evaluator = try evaluator(arguments)
    let missingRule = try string("missing_rule", in: arguments)
    let malformedRule = try string("malformed_rule", in: arguments)
    return .object([
      "missing": .object([
        "string": .string(try evaluator.getString(missingRule)),
        "list": stringList(try evaluator.getStringList(missingRule)),
        "elements": nodes(try evaluator.getElements(missingRule)),
      ]),
      "malformed": .object([
        "string": attemptXPath {
          .string(try evaluator.getString(malformedRule))
        },
        "list": attemptXPath {
          stringList(try evaluator.getStringList(malformedRule))
        },
        "elements": attemptXPath {
          nodes(try evaluator.getElements(malformedRule))
        },
      ]),
    ])
  }

  private static func xpathStringAndList(
    _ evaluator: SourceDOMSelectorEvaluator,
    rule: String
  ) -> JSONValue {
    .object([
      "string": attemptXPath {
        .string(try evaluator.getString(rule))
      },
      "list": attemptXPath {
        stringList(try evaluator.getStringList(rule))
      },
    ])
  }

  private static func attemptXPath(
    _ operation: () throws -> JSONValue
  ) -> JSONValue {
    attempt(
      exception:
        "org.seimicrawler.xpath.exception.XpathSyntaxErrorException",
      operation
    )
  }

  private static func attempt(
    exception: String,
    _ operation: () throws -> JSONValue
  ) -> JSONValue {
    do {
      return .object([
        "completed": .bool(true),
        "value": try operation(),
        "exception_type": .null,
      ])
    } catch {
      return .object([
        "completed": .bool(false),
        "value": .null,
        "exception_type": .string(exception),
      ])
    }
  }

  private static func nodes(
    _ values: [SourceDOMNodeProjection]
  ) -> JSONValue {
    .array(
      values.map { value in
        .object([
          "kind": .string(value.kind.rawValue),
          "as_string": .string(value.asString),
          "rendered": .string(value.rendered),
          "tag": value.tag.map(JSONValue.string) ?? .null,
        ])
      }
    )
  }

  private static func evaluator(
    _ arguments: [String: JSONValue]
  ) throws -> SourceDOMSelectorEvaluator {
    SourceDOMSelectorEvaluator(
      content: try string("content", in: arguments)
    )
  }

  private static func stringList(_ value: [String]) -> JSONValue {
    .array(value.map(JSONValue.string))
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

  private static func object(
    _ key: String,
    in object: [String: JSONValue]
  ) throws -> [String: JSONValue] {
    guard case .object(let value)? = object[key] else {
      throw SourcePipelineConformanceError.invalidSourceDefinition
    }
    return value
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
