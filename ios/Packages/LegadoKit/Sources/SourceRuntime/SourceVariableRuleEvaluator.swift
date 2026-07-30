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

  public init(
    content: String,
    resolver: SourceVariableResolver
  ) {
    self.content = content
    self.resolver = resolver
  }

  public func getString(_ rule: String?) async throws -> String {
    guard let rule, !rule.isEmpty else { return "" }
    let plan = SourceVariableRulePlan.parse(rule)
    for key in plan.writes.keys.sorted() {
      let value = try await getString(plan.writes[key])
      _ = await resolver.put(key, value: value)
    }
    if
      let value = try await variableScript(
        plan.executionRule,
        current: content
      )
    {
      return value
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
      let value = try await variableScript(
        plan.executionRule,
        current: content
      )
    {
      return [value]
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
    return try SourceRuleConsumerEvaluator(
      content: content
    ).getElements(plan.executionRule)
  }

  private func variableScript(
    _ rawRule: String,
    current: String
  ) async throws -> String? {
    let script: String
    if rawRule.lowercased().hasPrefix("@js:") {
      script = String(rawRule.dropFirst(4))
    } else if
      rawRule.lowercased().hasPrefix("<js>"),
      rawRule.lowercased().hasSuffix("</js>")
    {
      script = String(rawRule.dropFirst(4).dropLast(5))
    } else {
      return nil
    }
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
