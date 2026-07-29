import Foundation
import LegadoCore
import SourceRuntime

struct SourceRuleBackendDispatchConformanceRun: Sendable {
  let artifact: JSONValue
  let requestPlan: JSONValue
}

enum SourceRuleBackendDispatchConformanceRunner {
  static let fixtureID = "sl-source-rule-backend-dispatch-runtime-001"

  static func run(
    fixtureDirectory: URL
  ) throws -> SourceRuleBackendDispatchConformanceRun {
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
        inputCase["operation"] == .string("rule_backend_dispatch"),
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
          "operation": .string("rule_backend_dispatch"),
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
    return SourceRuleBackendDispatchConformanceRun(
      artifact: artifact,
      requestPlan: canonicalPlans
    )
  }

  private static func projection(
    _ arguments: [String: JSONValue]
  ) throws -> JSONValue {
    switch try string("mode", in: arguments) {
    case "html_prefix_dispatch":
      return try htmlPrefixDispatch(arguments)
    case "json_content_dispatch":
      return try jsonContentDispatch(arguments)
    case "javascript_dispatch":
      return try javaScriptDispatch(arguments)
    case "regex_stickiness":
      return try regexStickiness(arguments)
    case "parser_cache_lifecycle":
      return try parserCacheLifecycle(arguments)
    case "native_object_access":
      return try nativeObjectAccess(arguments)
    case "null_content":
      return nullContent()
    case "foreign_content_isolation":
      return try foreignContentIsolation(arguments)
    default:
      throw SourcePipelineConformanceError.invalidSourceDefinition
    }
  }

  private static func htmlPrefixDispatch(
    _ arguments: [String: JSONValue]
  ) throws -> JSONValue {
    let evaluator = SourceRuleEvaluator(
      content: try string("content", in: arguments)
    )
    let defaultValue = try evaluator.evaluate(
      string("default_rule", in: arguments)
    )
    let cssValue = try evaluator.evaluate(
      string("css_rule", in: arguments)
    )
    let escapedValue = try evaluator.evaluate(
      string("escaped_default_rule", in: arguments)
    )
    let xpathValue = try evaluator.evaluate(
      string("xpath_rule", in: arguments)
    )
    let leadingXPathValue = try evaluator.evaluate(
      string("leading_xpath_rule", in: arguments)
    )
    return .object([
      "default_value": try scalar(defaultValue),
      "css_value": try scalar(cssValue),
      "escaped_default_value": try scalar(escapedValue),
      "xpath_value": try scalar(xpathValue),
      "leading_xpath_value": try scalar(leadingXPathValue),
      "modes": .object([
        "default": descriptor(defaultValue),
        "css": descriptor(cssValue),
        "escaped_default": descriptor(escapedValue),
        "xpath": descriptor(xpathValue),
        "leading_xpath": descriptor(leadingXPathValue),
      ]),
    ])
  }

  private static func jsonContentDispatch(
    _ arguments: [String: JSONValue]
  ) throws -> JSONValue {
    let evaluator = SourceRuleEvaluator(
      content: try string("content", in: arguments)
    )
    let automatic = try evaluator.evaluate(
      string("auto_rule", in: arguments)
    )
    let signature = try evaluator.evaluate(
      string("signature_rule", in: arguments)
    )
    let explicit = try evaluator.evaluate(
      string("explicit_rule", in: arguments)
    )
    let list = try evaluator.evaluate(
      string("list_rule", in: arguments)
    )
    return .object([
      "auto_value": try scalar(automatic),
      "signature_value": try scalar(signature),
      "explicit_value": try scalar(explicit),
      "list_values": try stringArray(list),
      "modes": .object([
        "auto": descriptor(automatic),
        "signature": descriptor(signature),
        "explicit": descriptor(explicit),
        "list": descriptor(list),
      ]),
    ])
  }

  private static func javaScriptDispatch(
    _ arguments: [String: JSONValue]
  ) throws -> JSONValue {
    let evaluator = SourceRuleEvaluator(
      content: try string("content", in: arguments)
    )
    let embedded = try evaluator.evaluate(
      string("embedded_rule", in: arguments)
    )
    let tail = try evaluator.evaluate(
      string("tail_rule", in: arguments)
    )
    return .object([
      "embedded_mode": descriptor(embedded),
      "embedded_value": try scalar(embedded),
      "tail_mode": descriptor(tail),
      "tail_value": try scalar(tail),
    ])
  }

  private static func regexStickiness(
    _ arguments: [String: JSONValue]
  ) throws -> JSONValue {
    let evaluator = SourceRuleEvaluator(
      content: try string("content", in: arguments)
    )
    let activation = try evaluator.evaluate(
      string("activation_rule", in: arguments)
    )
    let followup = try evaluator.evaluate(
      string("followup_rule", in: arguments)
    )
    return .object([
      "activation_mode": descriptor(activation),
      "activation_values": activation.value,
      "followup_mode": descriptor(followup),
      "followup_values": followup.value,
    ])
  }

  private static func parserCacheLifecycle(
    _ arguments: [String: JSONValue]
  ) throws -> JSONValue {
    let css = try cacheProjection(
      backend: .defaultBackend,
      rule: string("css_rule", in: arguments),
      first: string("html_first", in: arguments),
      second: string("html_second", in: arguments)
    )
    let xpath = try cacheProjection(
      backend: .xpath,
      rule: string("xpath_rule", in: arguments),
      first: string("html_first", in: arguments),
      second: string("html_second", in: arguments)
    )
    let json = try cacheProjection(
      backend: .json,
      rule: string("json_rule", in: arguments),
      first: string("json_first", in: arguments),
      second: string("json_second", in: arguments)
    )
    return .object([
      "jsoup": css,
      "xpath": xpath,
      "jsonpath": json,
    ])
  }

  private static func cacheProjection(
    backend: SourceRuleBackend,
    rule: String,
    first: String,
    second: String
  ) throws -> JSONValue {
    let evaluator = SourceRuleEvaluator(content: first)
    let firstValue = try evaluator.evaluate(rule)
    let firstIdentity = evaluator.cacheIdentity(for: backend)
    let repeatedValue = try evaluator.evaluate(rule)
    let repeatedIdentity = evaluator.cacheIdentity(for: backend)
    try evaluator.setContent(second)
    let secondValue = try evaluator.evaluate(rule)
    let secondIdentity = evaluator.cacheIdentity(for: backend)
    return .object([
      "first_value": try scalar(firstValue),
      "repeated_value": try scalar(repeatedValue),
      "second_value": try scalar(secondValue),
      "same_instance_for_same_content": .bool(
        firstIdentity != nil && firstIdentity == repeatedIdentity
      ),
      "replaced_after_set_content": .bool(
        repeatedIdentity != nil
          && secondIdentity != nil
          && repeatedIdentity != secondIdentity
      ),
    ])
  }

  private static func nativeObjectAccess(
    _ arguments: [String: JSONValue]
  ) throws -> JSONValue {
    let object = try nativeObject(
      from: string("script", in: arguments)
    )
    let key = try string("key", in: arguments)
    let evaluation = SourceRuleEvaluator().evaluate(
      key,
      nativeObject: object
    )
    return .object([
      "direct_value": try scalar(evaluation),
      "rule_mode": descriptor(evaluation),
      "runtime_type": .string("org.mozilla.javascript.NativeObject"),
    ])
  }

  private static func nullContent() -> JSONValue {
    let evaluator = SourceRuleEvaluator()
    do {
      try evaluator.setContent(nil)
      return .object([
        "accepted": .bool(true),
        "exception_type": .null,
      ])
    } catch SourceRuleRuntimeError.missingContent {
      return .object([
        "accepted": .bool(false),
        "exception_type": .string("java.lang.AssertionError"),
      ])
    } catch {
      return .object([
        "accepted": .bool(false),
        "exception_type": .string("unexpected"),
      ])
    }
  }

  private static func foreignContentIsolation(
    _ arguments: [String: JSONValue]
  ) throws -> JSONValue {
    let evaluator = SourceRuleEvaluator(
      content: try string("current_content", in: arguments)
    )
    let rule = try string("rule", in: arguments)
    let currentBefore = try evaluator.evaluate(rule)
    let identityBefore = evaluator.cacheIdentity(for: .defaultBackend)
    let foreign = try evaluator.evaluate(
      rule,
      against: string("foreign_content", in: arguments)
    )
    let identityAfterForeign = evaluator.cacheIdentity(
      for: .defaultBackend
    )
    let currentAfter = try evaluator.evaluate(rule)
    let identityAfterCurrent = evaluator.cacheIdentity(
      for: .defaultBackend
    )
    return .object([
      "current_before": try scalar(currentBefore),
      "foreign_value": try scalar(foreign),
      "current_after": try scalar(currentAfter),
      "cache_preserved_after_foreign": .bool(
        identityBefore != nil && identityBefore == identityAfterForeign
      ),
      "cache_reused_after_foreign": .bool(
        identityAfterForeign != nil
          && identityAfterForeign == identityAfterCurrent
      ),
    ])
  }

  private static func descriptor(
    _ evaluation: SourceRuleEvaluation
  ) -> JSONValue {
    .array([
      .object([
        "mode": .string(evaluation.descriptor.mode.rawValue),
        "rule": .string(evaluation.descriptor.rule),
      ])
    ])
  }

  private static func scalar(
    _ evaluation: SourceRuleEvaluation
  ) throws -> JSONValue {
    guard case .string = evaluation.value else {
      throw SourcePipelineConformanceError.invalidSourceDefinition
    }
    return evaluation.value
  }

  private static func stringArray(
    _ evaluation: SourceRuleEvaluation
  ) throws -> JSONValue {
    guard
      case .array(let values) = evaluation.value,
      values.allSatisfy({
        if case .string = $0 { return true }
        return false
      })
    else {
      throw SourcePipelineConformanceError.invalidSourceDefinition
    }
    return evaluation.value
  }

  private static func nativeObject(
    from script: String
  ) throws -> [String: JSONValue] {
    guard
      script.hasPrefix("({"),
      script.hasSuffix("})")
    else {
      throw SourcePipelineConformanceError.invalidSourceDefinition
    }
    let body = script.dropFirst(2).dropLast(2)
    var result: [String: JSONValue] = [:]
    for entry in body.split(separator: ",") {
      let parts = entry.split(
        separator: ":",
        maxSplits: 1,
        omittingEmptySubsequences: false
      )
      guard parts.count == 2 else {
        throw SourcePipelineConformanceError.invalidSourceDefinition
      }
      let key = parts[0].trimmingCharacters(in: .whitespaces)
      let raw = parts[1].trimmingCharacters(in: .whitespaces)
      if raw.count >= 2,
        let quote = raw.first,
        (quote == "'" || quote == "\""),
        raw.last == quote
      {
        result[key] = .string(String(raw.dropFirst().dropLast()))
      } else if let integer = Int64(raw) {
        result[key] = .number(JSONNumber(integer))
      } else {
        throw SourcePipelineConformanceError.invalidSourceDefinition
      }
    }
    return result
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
