import Foundation
import LegadoCore
import RuleRuntime

/// Android-compatible consumers for the bounded rule-combination surface that
/// has been frozen by the SourceLab Golden. The intermediate `JSONValue`
/// remains typed until a consumer converts it to text, a list, or an element.
public struct SourceRuleConsumerEvaluator: Sendable {
  public let content: String
  public let htmlSelectorBackend: (any HTMLSelectorBackend)?

  public init(
    content: String,
    htmlSelectorBackend: (any HTMLSelectorBackend)? = nil
  ) {
    self.content = content
    self.htmlSelectorBackend = htmlSelectorBackend
  }

  public func getString(_ rule: String?) throws -> String {
    guard let rule, !rule.isEmpty else { return "" }
    if rule.contains("##") {
      return SourceRegexReplacementEvaluator(content: content).getString(rule)
    }
    var current: ConsumerValue = .string(content)
    for stage in stages(rule) {
      switch stage {
      case .rule(let value):
        current = try stringRule(value)
      case .javaScript(let script):
        current = try javaScript(script, current: current)
      }
    }
    return stringValue(current)
  }

  public func getString(
    _ rule: String?,
    isURL: Bool,
    urlContext: SourceRuleURLContext
  ) throws -> String {
    let value = try getString(rule)
    return isURL ? urlContext.absoluteString(value) : value
  }

  public func getStringList(
    _ rule: String?,
    isURL: Bool = false,
    redirectURL: URL? = nil
  ) throws -> [String]? {
    guard let rule, !rule.isEmpty else { return nil }
    if rule.contains("##") {
      return SourceRegexReplacementEvaluator(content: content)
        .getStringList(rule)
    }
    var current: ConsumerValue = .string(content)
    for stage in stages(rule) {
      switch stage {
      case .rule(let value):
        current = try listRule(value)
      case .javaScript(let script):
        current = try javaScript(script, current: current)
      }
    }
    let values = listValue(current)
    guard isURL else { return values }
    guard let redirectURL else {
      throw SourceRuleRuntimeError.missingRedirectURL
    }
    var result: [String] = []
    for value in values {
      let resolved =
        value.isEmpty
        ? redirectURL.absoluteString
        : URL(string: value, relativeTo: redirectURL)?
          .absoluteURL.absoluteString
      guard
        let resolved,
        !resolved.isEmpty,
        !result.contains(resolved)
      else { continue }
      result.append(resolved)
    }
    return result
  }

  public func getStringList(
    _ rule: String?,
    isURL: Bool,
    urlContext: SourceRuleURLContext
  ) throws -> [String]? {
    guard let values = try getStringList(rule) else { return nil }
    return isURL ? urlContext.absoluteList(values) : values
  }

  public func getElement(_ rule: String) throws -> JSONValue? {
    guard !rule.isEmpty else { return nil }
    if isDOMRule(rule) {
      return try SourceDOMSelectorEvaluator(
        content: content,
        htmlSelectorBackend: htmlSelectorBackend
      ).getElements(rule).first.map {
        .string($0.asString)
      }
    }
    if isJSONRule(rule) {
      return try jsonPathEvaluator().getElement(rule)
    }
    return try evaluateJSONPath(rule)
  }

  public func getElements(_ rule: String) throws -> [JSONValue] {
    guard !rule.isEmpty else { return [] }
    if isDOMRule(rule) {
      return try SourceDOMSelectorEvaluator(
        content: content,
        htmlSelectorBackend: htmlSelectorBackend
      ).getElements(rule).map {
        .string($0.asString)
      }
    }
    if isJSONRule(rule) {
      return try jsonPathEvaluator().getElements(rule)
    }
    guard case .array(let values) = try evaluateJSONPath(rule) else {
      return []
    }
    return values
  }

  private enum ConsumerValue {
    case string(String)
    case list([String])
    case json(JSONValue)
  }

  private enum Stage {
    case rule(String)
    case javaScript(String)
  }

  private enum CombinationOperator: String {
    case concatenate = "&&"
    case fallback = "||"
    case interleave = "%%"
  }

  private func stages(_ rule: String) -> [Stage] {
    if let script = javaScriptBody(rule) {
      return [.javaScript(script)]
    }
    guard
      let open = rule.range(of: "<js>", options: .caseInsensitive),
      let close = rule.range(
        of: "</js>",
        options: [.caseInsensitive, .backwards]
      ),
      open.upperBound <= close.lowerBound,
      close.upperBound == rule.endIndex
    else {
      return [.rule(rule)]
    }
    var result: [Stage] = []
    let prefix = String(rule[..<open.lowerBound])
    if !prefix.isEmpty {
      result.append(.rule(prefix))
    }
    result.append(
      .javaScript(String(rule[open.upperBound..<close.lowerBound]))
    )
    return result
  }

  private func javaScriptBody(_ rule: String) -> String? {
    guard rule.lowercased().hasPrefix("@js:") else { return nil }
    return String(rule.dropFirst(4))
  }

  private func stringRule(_ rule: String) throws -> ConsumerValue {
    if isJSONRule(rule) {
      return .string(try jsonPathEvaluator().getString(rule))
    }
    if rule.contains(CombinationOperator.interleave.rawValue) {
      // Android's JSON string consumer only recognizes && and ||. A %%
      // expression therefore reaches JSONPath as an unsupported path and
      // becomes an empty string.
      return .string("")
    }
    if let combination = combination(rule, allowed: [.concatenate, .fallback]) {
      var values: [String] = []
      for component in combination.components {
        let value = scalarString(try evaluateJSONPath(component))
        guard !value.isEmpty else { continue }
        values.append(value)
        if combination.operation == .fallback { break }
      }
      return .string(values.joined(separator: "\n"))
    }
    if isDOMRule(rule) {
      return .string(try domTextValues(rule).joined(separator: "\n"))
    }
    return .json(try evaluateJSONPath(rule))
  }

  private func listRule(_ rule: String) throws -> ConsumerValue {
    if isJSONRule(rule) {
      return .list(try jsonPathEvaluator().getStringList(rule))
    }
    if let combination = combination(
      rule,
      allowed: [.concatenate, .fallback, .interleave]
    ) {
      var groups: [[String]] = []
      for component in combination.components {
        let values = scalarList(try evaluateJSONPath(component))
        guard !values.isEmpty else { continue }
        groups.append(values)
        if combination.operation == .fallback { break }
      }
      switch combination.operation {
      case .concatenate, .fallback:
        return .list(groups.flatMap { $0 })
      case .interleave:
        guard let first = groups.first else { return .list([]) }
        var values: [String] = []
        for index in first.indices {
          for group in groups where group.indices.contains(index) {
            values.append(group[index])
          }
        }
        return .list(values)
      }
    }
    if isDOMRule(rule) {
      return .list(try domTextValues(rule))
    }
    return .json(try evaluateJSONPath(rule))
  }

  private func combination(
    _ rule: String,
    allowed: [CombinationOperator]
  ) -> (operation: CombinationOperator, components: [String])? {
    for operation in allowed where rule.contains(operation.rawValue) {
      let values = rule.components(separatedBy: operation.rawValue)
      guard values.count > 1 else { continue }
      return (operation, values)
    }
    return nil
  }

  private func evaluateJSONPath(_ rawRule: String) throws -> JSONValue {
    let evaluator = SourceRuleEvaluator(content: content)
    return try evaluator.evaluate(rawRule).value
  }

  private func isJSONRule(_ rule: String) -> Bool {
    rule.lowercased().hasPrefix("@json:")
      || rule.hasPrefix("$")
      || (try? JSONValueCodec.decode(Data(content.utf8))) != nil
  }

  private func jsonPathEvaluator() throws -> SourceJSONPathEvaluator {
    do {
      return try SourceJSONPathEvaluator(input: .jsonString(content))
    } catch {
      throw SourceRuleRuntimeError.malformedContent(.json)
    }
  }

  private func isDOMRule(_ rule: String) -> Bool {
    let lowercased = rule.lowercased()
    return lowercased.hasPrefix("@css:")
      || lowercased.hasPrefix("@xpath:")
      || rule.hasPrefix("//")
  }

  private func domTextValues(_ rawRule: String) throws -> [String] {
    do {
      return try SourceDOMSelectorEvaluator(
        content: content,
        htmlSelectorBackend: htmlSelectorBackend
      ).getStringList(rawRule)
    } catch let error as SourceDOMSelectorError {
      if case .malformedXPath = error { throw error }
      throw SourceRuleRuntimeError.malformedContent(.defaultBackend)
    } catch {
      throw SourceRuleRuntimeError.malformedContent(.defaultBackend)
    }
  }

  private func javaScript(
    _ rawScript: String,
    current: ConsumerValue
  ) throws -> ConsumerValue {
    let script = rawScript.trimmingCharacters(in: .whitespacesAndNewlines)
    if script.hasPrefix("throw ") {
      throw SourceRuleRuntimeError.scriptFailure
    }
    if let literal = javaScriptStringLiteral(script) {
      return .string(literal)
    }
    if let suffix = javaScriptStringSuffix(script) {
      return .string(stringValue(current) + suffix)
    }
    if let joined = javaScriptListJoin(script, current: current) {
      return .string(joined)
    }
    throw SourceRuleRuntimeError.unsupportedRule(.javaScript, rawScript)
  }

  private func javaScriptStringLiteral(_ script: String) -> String? {
    guard
      script.count >= 2,
      let quote = script.first,
      quote == "'" || quote == "\"",
      script.last == quote
    else { return nil }
    return decodeJavaScriptEscapes(String(script.dropFirst().dropLast()))
  }

  private func javaScriptStringSuffix(_ script: String) -> String? {
    let prefix = "result.toString()"
    guard script.hasPrefix(prefix) else { return nil }
    let remainder = script.dropFirst(prefix.count)
      .trimmingCharacters(in: .whitespaces)
    guard remainder.hasPrefix("+") else { return nil }
    return javaScriptStringLiteral(
      String(remainder.dropFirst()).trimmingCharacters(in: .whitespaces)
    )
  }

  private func javaScriptListJoin(
    _ script: String,
    current: ConsumerValue
  ) -> String? {
    guard case .list(let values) = current else { return nil }
    let pattern =
      #"^result\.get\((\d+)\)\.toString\(\)\s*\+\s*(['"])(.*?)\2\s*\+\s*result\.get\((\d+)\)\.toString\(\)$"#
    guard
      let expression = try? NSRegularExpression(pattern: pattern),
      let match = expression.firstMatch(
        in: script,
        range: NSRange(script.startIndex..., in: script)
      ),
      let firstRange = Range(match.range(at: 1), in: script),
      let separatorRange = Range(match.range(at: 3), in: script),
      let secondRange = Range(match.range(at: 4), in: script),
      let first = Int(script[firstRange]),
      let second = Int(script[secondRange]),
      values.indices.contains(first),
      values.indices.contains(second)
    else { return nil }
    return values[first]
      + decodeJavaScriptEscapes(String(script[separatorRange]))
      + values[second]
  }

  private func decodeJavaScriptEscapes(_ value: String) -> String {
    var result = ""
    var escaped = false
    for character in value {
      if escaped {
        switch character {
        case "n": result.append("\n")
        case "r": result.append("\r")
        case "t": result.append("\t")
        case "\\": result.append("\\")
        case "'", "\"": result.append(character)
        default:
          result.append("\\")
          result.append(character)
        }
        escaped = false
      } else if character == "\\" {
        escaped = true
      } else {
        result.append(character)
      }
    }
    if escaped { result.append("\\") }
    return result
  }

  private func stringValue(_ value: ConsumerValue) -> String {
    switch value {
    case .string(let string):
      string
    case .list(let values):
      values.joined(separator: "\n")
    case .json(let value):
      scalarString(value)
    }
  }

  private func listValue(_ value: ConsumerValue) -> [String] {
    switch value {
    case .string(let string):
      string.components(separatedBy: "\n")
    case .list(let values):
      values
    case .json(let value):
      scalarList(value)
    }
  }

  private func scalarString(_ value: JSONValue) -> String {
    switch value {
    case .null:
      ""
    case .bool(let value):
      value ? "true" : "false"
    case .number(let value):
      value.rawToken
    case .string(let value):
      value
    case .array(let values):
      values.map(scalarString).joined(separator: "\n")
    case .object:
      ""
    }
  }

  private func scalarList(_ value: JSONValue) -> [String] {
    switch value {
    case .null:
      []
    case .array(let values):
      values.compactMap { value in
        guard value != .null else { return nil }
        return scalarString(value)
      }
    case .object:
      []
    default:
      [scalarString(value)]
    }
  }
}
