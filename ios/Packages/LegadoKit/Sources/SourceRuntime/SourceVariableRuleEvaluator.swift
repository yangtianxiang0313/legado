import Foundation
import LegadoCore

public struct SourceVariableRulePlan: Sendable, Equatable {
  public let executionRule: String
  public let writes: [String: String]

  public static func parse(_ rule: String) -> SourceVariableRulePlan {
    let pattern = #"@put:(\{[^}]+?\})"#
    guard
      let regex = try? NSRegularExpression(
        pattern: pattern,
        options: [.caseInsensitive]
      )
    else {
      return SourceVariableRulePlan(
        executionRule: rule,
        writes: [:]
      )
    }
    let range = NSRange(rule.startIndex..., in: rule)
    let matches = regex.matches(in: rule, range: range)
    var writes: [String: String] = [:]
    for match in matches {
      guard
        let jsonRange = Range(match.range(at: 1), in: rule),
        let data = String(rule[jsonRange]).data(using: .utf8),
        let values = try? JSONDecoder().decode(
          [String: String].self,
          from: data
        )
      else {
        continue
      }
      writes.merge(values) { _, latest in latest }
    }
    let executionRule = regex.stringByReplacingMatches(
      in: rule,
      range: range,
      withTemplate: ""
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    return SourceVariableRulePlan(
      executionRule: executionRule,
      writes: writes
    )
  }
}

public struct SourceVariableRuleEvaluator: Sendable {
  public let content: String
  public let resolver: SourceVariableResolver
  public let scriptRuntime: (any SourceScriptRuntime)?
  public let scriptSessionID: SourceScriptSessionID?
  public let scriptLibrary: SourceScriptLibrary?
  public let baseURL: String?

  public init(
    content: String,
    resolver: SourceVariableResolver,
    scriptRuntime: (any SourceScriptRuntime)? = nil,
    scriptSessionID: SourceScriptSessionID? = nil,
    scriptLibrary: SourceScriptLibrary? = nil,
    baseURL: String? = nil
  ) {
    self.content = content
    self.resolver = resolver
    self.scriptRuntime = scriptRuntime
    self.scriptSessionID = scriptSessionID
    self.scriptLibrary = scriptLibrary
    self.baseURL = baseURL
  }

  public func getString(_ rule: String?) async throws -> String {
    guard let rule, !rule.isEmpty else { return "" }
    let plan = SourceVariableRulePlan.parse(rule)
    for key in plan.writes.keys.sorted() {
      let value = try await getString(plan.writes[key])
      _ = await resolver.put(key, value: value)
    }
    if
      let value = try await scriptValue(
        plan.executionRule,
        current: content
      )
    {
      return stringValue(value)
    }
    return try SourceRuleConsumerEvaluator(
      content: content
    ).getString(plan.executionRule)
  }

  public func getStringList(
    _ rule: String?
  ) async throws -> [String]? {
    guard let rule, !rule.isEmpty else { return nil }
    let plan = SourceVariableRulePlan.parse(rule)
    for key in plan.writes.keys.sorted() {
      let value = try await getString(plan.writes[key])
      _ = await resolver.put(key, value: value)
    }
    if
      let value = try await scriptValue(
        plan.executionRule,
        current: content
      )
    {
      return listValue(value)
    }
    return try SourceRuleConsumerEvaluator(
      content: content
    ).getStringList(plan.executionRule)
  }

  public func getElements(_ rule: String) async throws -> [JSONValue] {
    let plan = SourceVariableRulePlan.parse(rule)
    for key in plan.writes.keys.sorted() {
      let value = try await getString(plan.writes[key])
      _ = await resolver.put(key, value: value)
    }
    if
      let value = try await scriptValue(
        plan.executionRule,
        current: content
      )
    {
      switch value {
      case .array(let values):
        return try values.map(jsonValue)
      case .undefined, .null:
        return []
      default:
        return [try jsonValue(value)]
      }
    }
    return try SourceRuleConsumerEvaluator(
      content: content
    ).getElements(plan.executionRule)
  }

  private func scriptValue(
    _ rawRule: String,
    current: String
  ) async throws -> SourceScriptValue? {
    guard let script = scriptBody(rawRule) else {
      return nil
    }
    if
      let scriptRuntime,
      let scriptSessionID
    {
      return try await scriptRuntime.evaluate(
        SourceScriptRequest(
          sessionID: scriptSessionID,
          library: scriptLibrary,
          script: script,
          result: .string(current),
          baseURL: baseURL
        ),
        host: SourceVariableScriptHost(resolver: resolver)
      )
    }
    return try await legacyScriptValue(script, current: current)
      .map(SourceScriptValue.string)
  }

  private func scriptBody(_ rawRule: String) -> String? {
    if rawRule.lowercased().hasPrefix("@js:") {
      return String(rawRule.dropFirst(4))
    } else if
      rawRule.lowercased().hasPrefix("<js>"),
      rawRule.lowercased().hasSuffix("</js>")
    {
      return String(rawRule.dropFirst(4).dropLast(5))
    }
    return nil
  }

  private func legacyScriptValue(
    _ script: String,
    current: String
  ) async throws -> String? {
    let normalized = script.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    if
      let key = capture(
        #"^java\.get\(\s*(['"])(.*?)\1\s*\)$"#,
        group: 2,
        in: normalized
      )
    {
      return await resolver.get(key)
    }
    guard
      let match = captures(
        #"^java\.put\(\s*(['"])(.*?)\1\s*,\s*(.*?)\s*\)$"#,
        in: normalized
      ),
      match.count == 3
    else {
      return nil
    }
    let key = match[1]
    let valueExpression = match[2]
    let value: String
    if valueExpression == "result.toString()" {
      value = current
    } else if
      let referenced = capture(
        #"^java\.get\(\s*(['"])(.*?)\1\s*\)$"#,
        group: 2,
        in: valueExpression
      )
    {
      value = await resolver.get(referenced)
    } else if
      let literal = quotedLiteral(valueExpression)
    {
      value = literal
    } else {
      throw SourceRuleRuntimeError.unsupportedRule(
        .javaScript,
        normalized
      )
    }
    return await resolver.put(key, value: value)
  }

  private func stringValue(_ value: SourceScriptValue) -> String {
    switch value {
    case .undefined, .null:
      return ""
    case .bool(let value):
      return String(value)
    case .number(let value):
      return numberString(value)
    case .string(let value):
      return value
    case .array(let values):
      return values.map(stringValue).joined(separator: "\n")
    case .object:
      return ""
    }
  }

  private func listValue(_ value: SourceScriptValue) -> [String] {
    switch value {
    case .undefined, .null:
      return []
    case .array(let values):
      return values.map(stringValue)
    default:
      return [stringValue(value)]
    }
  }

  private func jsonValue(
    _ value: SourceScriptValue
  ) throws -> JSONValue {
    switch value {
    case .undefined, .null:
      return .null
    case .bool(let value):
      return .bool(value)
    case .number(let value):
      return .number(
        try JSONNumber(validating: numberString(value))
      )
    case .string(let value):
      return .string(value)
    case .array(let values):
      return .array(try values.map(jsonValue))
    case .object(let values):
      return .object(try values.mapValues(jsonValue))
    }
  }

  private func numberString(_ value: Double) -> String {
    if value.rounded() == value,
      value >= Double(Int64.min),
      value <= Double(Int64.max)
    {
      return String(Int64(value))
    }
    return String(value)
  }

  private func quotedLiteral(_ value: String) -> String? {
    guard
      value.count >= 2,
      let quote = value.first,
      quote == "'" || quote == "\"",
      value.last == quote
    else {
      return nil
    }
    return String(value.dropFirst().dropLast())
  }

  private func capture(
    _ pattern: String,
    group: Int,
    in value: String
  ) -> String? {
    guard
      let values = captures(pattern, in: value),
      values.indices.contains(group - 1)
    else {
      return nil
    }
    return values[group - 1]
  }

  private func captures(
    _ pattern: String,
    in value: String
  ) -> [String]? {
    guard
      let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(
        in: value,
        range: NSRange(value.startIndex..., in: value)
      )
    else {
      return nil
    }
    return (1..<match.numberOfRanges).compactMap { index in
      guard let range = Range(match.range(at: index), in: value) else {
        return nil
      }
      return String(value[range])
    }
  }
}
