import Foundation
import LegadoCore

public enum SourceJSONPathBackendError: Error, Sendable, Equatable {
  case malformedInput
  case pathNotFound
  case invalidPath
  case nullElement
}

public enum SourceRegexBackendError: Error, Sendable, Equatable {
  case invalidPattern
  case unmatchedGroup
}

/// The source of a JSONPath evaluation matters at the Android boundary:
/// object input is converted through Java numeric objects while textual JSON
/// keeps the number tokens parsed from the response.
public enum SourceJSONPathInput: Sendable, Equatable {
  case jsonString(String)
  case object(JSONValue)
}

/// A bounded, deterministic JSONPath compatibility kernel. It intentionally
/// implements only syntax observed by protected Android Goldens.
public struct SourceJSONPathEvaluator: Sendable {
  private enum InputStyle: Sendable, Equatable {
    case textualJSON
    case nativeObject
  }

  private enum Combination: String {
    case concatenate = "&&"
    case fallback = "||"
    case interleave = "%%"
  }

  private enum Comparison {
    case lessThan
    case lessThanOrEqual
    case greaterThan
    case greaterThanOrEqual
    case equal
  }

  private enum Step {
    case field(String)
    case index(Int)
    case wildcard
    case slice(Int?, Int?)
    case filter(field: String, comparison: Comparison, number: Double)
    case recursiveField(String)

    var isPlural: Bool {
      switch self {
      case .wildcard, .slice, .filter, .recursiveField:
        true
      case .field, .index:
        false
      }
    }
  }

  private let root: JSONValue
  private let inputStyle: InputStyle

  public init(input: SourceJSONPathInput) throws {
    switch input {
    case .jsonString(let content):
      do {
        self.root = try JSONValueCodec.decode(Data(content.utf8))
      } catch {
        throw SourceJSONPathBackendError.malformedInput
      }
      self.inputStyle = .textualJSON
    case .object(let value):
      self.root = value
      self.inputStyle = .nativeObject
    }
  }

  public func getString(_ rule: String) -> String {
    let normalized = normalizedRule(rule)
    if normalized.contains(Combination.interleave.rawValue) {
      return ""
    }
    if let value = interpolatedString(normalized) {
      return value
    }
    if let combination = combination(
      normalized,
      allowed: [.concatenate, .fallback]
    ) {
      var values: [String] = []
      for component in combination.components {
        let value = stringValue((try? evaluatePath(component)) ?? .null)
        guard !value.isEmpty else { continue }
        values.append(value)
        if combination.operation == .fallback { break }
      }
      return values.joined(separator: "\n")
    }
    return stringValue((try? evaluatePath(normalized)) ?? .null)
  }

  public func getStringList(_ rule: String) -> [String] {
    let normalized = normalizedRule(rule)
    if let value = interpolatedString(normalized) {
      return [value]
    }
    if let combination = combination(
      normalized,
      allowed: [.concatenate, .fallback, .interleave]
    ) {
      var groups: [[String]] = []
      for component in combination.components {
        let values = listValue((try? evaluatePath(component)) ?? .null)
        guard !values.isEmpty else { continue }
        groups.append(values)
        if combination.operation == .fallback { break }
      }
      switch combination.operation {
      case .concatenate, .fallback:
        return groups.flatMap { $0 }
      case .interleave:
        guard let first = groups.first else { return [] }
        var result: [String] = []
        for index in first.indices {
          for group in groups where group.indices.contains(index) {
            result.append(group[index])
          }
        }
        return result
      }
    }
    return listValue((try? evaluatePath(normalized)) ?? .null)
  }

  public func getElement(_ rule: String) throws -> JSONValue {
    let normalized = normalizedRule(rule)
    if normalized.contains(Combination.concatenate.rawValue)
      || normalized.contains(Combination.interleave.rawValue)
    {
      return .array([])
    }
    if normalized.contains(Combination.fallback.rawValue)
      || interpolatedString(normalized) != nil
    {
      throw SourceJSONPathBackendError.pathNotFound
    }
    let value = try evaluatePath(normalized)
    guard value != .null else {
      throw SourceJSONPathBackendError.nullElement
    }
    return value
  }

  public func getElements(_ rule: String) -> [JSONValue] {
    let normalized = normalizedRule(rule)
    if interpolatedString(normalized) != nil {
      return []
    }
    if let combination = combination(
      normalized,
      allowed: [.concatenate, .fallback, .interleave]
    ) {
      var groups: [[JSONValue]] = []
      for component in combination.components {
        let values = elementList((try? evaluatePath(component)) ?? .null)
        guard !values.isEmpty else { continue }
        groups.append(values)
        if combination.operation == .fallback { break }
      }
      switch combination.operation {
      case .concatenate, .fallback:
        return groups.flatMap { $0 }
      case .interleave:
        guard let first = groups.first else { return [] }
        var result: [JSONValue] = []
        for index in first.indices {
          for group in groups where group.indices.contains(index) {
            result.append(group[index])
          }
        }
        return result
      }
    }
    return elementList((try? evaluatePath(normalized)) ?? .null)
  }

  private func normalizedRule(_ rule: String) -> String {
    rule.lowercased().hasPrefix("@json:")
      ? String(rule.dropFirst(6))
      : rule
  }

  private func combination(
    _ rule: String,
    allowed: [Combination]
  ) -> (operation: Combination, components: [String])? {
    for operation in allowed where rule.contains(operation.rawValue) {
      let components = rule.components(separatedBy: operation.rawValue)
      guard components.count > 1 else { continue }
      return (operation, components)
    }
    return nil
  }

  private func interpolatedString(_ rule: String) -> String? {
    guard rule.contains("{$") else { return nil }
    var result = ""
    var remainder = rule[...]
    while let opening = remainder.range(of: "{$") {
      result.append(contentsOf: remainder[..<opening.lowerBound])
      guard let closing = remainder[opening.upperBound...].firstIndex(of: "}")
      else {
        return nil
      }
      let path = String(remainder[remainder.index(after: opening.lowerBound)..<closing])
      guard let value = try? evaluatePath(path) else { return nil }
      result.append(stringValue(value))
      remainder = remainder[remainder.index(after: closing)...]
    }
    result.append(contentsOf: remainder)
    return result
  }

  private func evaluatePath(_ rawPath: String) throws -> JSONValue {
    let steps = try parse(rawPath)
    var values = [root]
    var plural = false
    for step in steps {
      plural = plural || step.isPlural
      switch step {
      case .field(let name):
        values = values.compactMap { value in
          guard case .object(let object) = value else { return nil }
          return object[name]
        }
      case .index(let index):
        values = values.compactMap { value in
          guard case .array(let array) = value else { return nil }
          let resolved = index >= 0 ? index : array.count + index
          guard array.indices.contains(resolved) else { return nil }
          return array[resolved]
        }
      case .wildcard:
        values = values.flatMap { value -> [JSONValue] in
          guard case .array(let array) = value else { return [] }
          return array
        }
      case .slice(let rawStart, let rawEnd):
        values = values.flatMap { value -> [JSONValue] in
          guard case .array(let array) = value else { return [] }
          let start = resolvedSliceIndex(rawStart ?? 0, count: array.count)
          let end = resolvedSliceIndex(rawEnd ?? array.count, count: array.count)
          guard start < end else { return [] }
          // Jayway's result for the protected `[0:3:2]` case includes the
          // complete bounded slice. Keep that observed behavior instead of
          // importing another JSONPath dialect's step semantics.
          return Array(array[start..<end])
        }
      case .filter(let field, let comparison, let number):
        values = values.flatMap { value -> [JSONValue] in
          guard case .array(let array) = value else { return [] }
          return array.filter { item in
            guard
              case .object(let object) = item,
              case .number(let candidate)? = object[field],
              let value = Double(candidate.rawToken)
            else {
              return false
            }
            switch comparison {
            case .lessThan: return value < number
            case .lessThanOrEqual: return value <= number
            case .greaterThan: return value > number
            case .greaterThanOrEqual: return value >= number
            case .equal: return value == number
            }
          }
        }
      case .recursiveField(let name):
        values = values.flatMap { recursiveValues(named: name, in: $0) }
      }
      guard !values.isEmpty else {
        throw SourceJSONPathBackendError.pathNotFound
      }
    }
    if plural {
      return .array(values)
    }
    guard let value = values.first else {
      throw SourceJSONPathBackendError.pathNotFound
    }
    return value
  }

  private func parse(_ path: String) throws -> [Step] {
    guard path.first == "$" else {
      throw SourceJSONPathBackendError.invalidPath
    }
    var steps: [Step] = []
    var index = path.index(after: path.startIndex)
    while index < path.endIndex {
      if path[index] == "." {
        let next = path.index(after: index)
        if next < path.endIndex, path[next] == "." {
          index = path.index(after: next)
          let field = readField(path, index: &index)
          guard !field.isEmpty else {
            throw SourceJSONPathBackendError.invalidPath
          }
          steps.append(.recursiveField(field))
        } else {
          index = next
          let field = readField(path, index: &index)
          guard !field.isEmpty else {
            throw SourceJSONPathBackendError.invalidPath
          }
          steps.append(.field(field))
        }
      } else if path[index] == "[" {
        guard let closing = path[index...].firstIndex(of: "]") else {
          throw SourceJSONPathBackendError.invalidPath
        }
        let token = String(path[path.index(after: index)..<closing])
        steps.append(try bracketStep(token))
        index = path.index(after: closing)
      } else {
        throw SourceJSONPathBackendError.invalidPath
      }
    }
    return steps
  }

  private func readField(
    _ path: String,
    index: inout String.Index
  ) -> String {
    let start = index
    while index < path.endIndex, path[index] != ".", path[index] != "[" {
      index = path.index(after: index)
    }
    return String(path[start..<index])
  }

  private func bracketStep(_ token: String) throws -> Step {
    if token == "*" {
      return .wildcard
    }
    if token.count >= 2,
      let quote = token.first,
      quote == "'" || quote == "\"",
      token.last == quote
    {
      return .field(String(token.dropFirst().dropLast()))
    }
    if token.hasPrefix("?(") {
      return try filterStep(token)
    }
    if token.contains(":") {
      let parts = token.split(
        separator: ":",
        omittingEmptySubsequences: false
      )
      guard parts.count == 2 || parts.count == 3 else {
        throw SourceJSONPathBackendError.invalidPath
      }
      let start = parts[0].isEmpty ? nil : Int(parts[0])
      let end = parts[1].isEmpty ? nil : Int(parts[1])
      guard
        parts[0].isEmpty || start != nil,
        parts[1].isEmpty || end != nil,
        parts.count != 3 || Int(parts[2]) != nil
      else {
        throw SourceJSONPathBackendError.invalidPath
      }
      return .slice(start, end)
    }
    guard let index = Int(token) else {
      throw SourceJSONPathBackendError.invalidPath
    }
    return .index(index)
  }

  private func filterStep(_ token: String) throws -> Step {
    let pattern =
      #"^\?\(@\.([A-Za-z0-9_-]+)\s*(<=|>=|==|<|>)\s*(-?[0-9]+(?:\.[0-9]+)?)\)$"#
    guard
      let expression = try? NSRegularExpression(pattern: pattern),
      let match = expression.firstMatch(
        in: token,
        range: NSRange(token.startIndex..., in: token)
      ),
      let fieldRange = Range(match.range(at: 1), in: token),
      let operatorRange = Range(match.range(at: 2), in: token),
      let numberRange = Range(match.range(at: 3), in: token),
      let number = Double(token[numberRange])
    else {
      throw SourceJSONPathBackendError.invalidPath
    }
    let comparison: Comparison
    switch token[operatorRange] {
    case "<": comparison = .lessThan
    case "<=": comparison = .lessThanOrEqual
    case ">": comparison = .greaterThan
    case ">=": comparison = .greaterThanOrEqual
    case "==": comparison = .equal
    default:
      throw SourceJSONPathBackendError.invalidPath
    }
    return .filter(
      field: String(token[fieldRange]),
      comparison: comparison,
      number: number
    )
  }

  private func resolvedSliceIndex(_ value: Int, count: Int) -> Int {
    min(max(value >= 0 ? value : count + value, 0), count)
  }

  private func recursiveValues(
    named name: String,
    in value: JSONValue
  ) -> [JSONValue] {
    switch value {
    case .object(let object):
      var result: [JSONValue] = []
      if let direct = object[name] {
        result.append(direct)
      }
      for key in object.keys.sorted() {
        result.append(
          contentsOf: recursiveValues(
            named: name,
            in: object[key] ?? .null
          )
        )
      }
      return result
    case .array(let array):
      return array.flatMap { recursiveValues(named: name, in: $0) }
    case .null, .bool, .number, .string:
      return []
    }
  }

  private func stringValue(_ value: JSONValue) -> String {
    switch value {
    case .null:
      ""
    case .array(let values):
      values.map(javaText).joined(separator: "\n")
    default:
      javaText(value)
    }
  }

  private func listValue(_ value: JSONValue) -> [String] {
    switch value {
    case .null:
      []
    case .array(let values):
      values.map(javaText)
    default:
      [javaText(value)]
    }
  }

  private func elementList(_ value: JSONValue) -> [JSONValue] {
    guard case .array(let values) = value else { return [] }
    return values
  }

  private func javaText(_ value: JSONValue) -> String {
    switch value {
    case .null:
      return "null"
    case .bool(let value):
      return value ? "true" : "false"
    case .number(let value):
      if inputStyle == .nativeObject,
        !value.rawToken.contains("."),
        !value.rawToken.lowercased().contains("e")
      {
        return value.rawToken + ".0"
      }
      return value.rawToken
    case .string(let value):
      return value
    case .array(let values):
      return "[" + values.map(javaText).joined(separator: ", ") + "]"
    case .object(let object):
      let keys =
        inputStyle == .nativeObject
        ? object.keys.sorted()
        : object.keys.sorted(by: >)
      return "{"
        + keys.map { key in "\(key)=\(javaText(object[key] ?? .null))" }
        .joined(separator: ", ")
        + "}"
    }
  }
}

/// Java-Pattern-compatible behavior for the bounded capture surface observed
/// by the Android Golden. Java exception classes are represented by stable
/// Swift errors and mapped only at Conformance boundaries.
public struct SourceRegexEvaluator: Sendable {
  public init() {}

  public func getElement(
    content: String,
    rule: String
  ) throws -> [String]? {
    let components = regexComponents(rule)
    var current = content
    for (index, component) in components.enumerated() {
      let expression = try compiled(component)
      guard
        let match = expression.firstMatch(
          in: current,
          range: NSRange(current.startIndex..., in: current)
        )
      else {
        return nil
      }
      if index == components.index(before: components.endIndex) {
        return try captures(match, in: current, unmatchedIsError: true)
      }
      current = try fullMatch(match, in: current)
    }
    return nil
  }

  public func getElements(
    content: String,
    rule: String
  ) throws -> [[String]] {
    let components = regexComponents(rule)
    var candidates = [content]
    for (index, component) in components.enumerated() {
      let expression = try compiled(component)
      var next: [String] = []
      var result: [[String]] = []
      for candidate in candidates {
        let matches = expression.matches(
          in: candidate,
          range: NSRange(candidate.startIndex..., in: candidate)
        )
        if index == components.index(before: components.endIndex) {
          result.append(
            contentsOf: try matches.map {
              try captures($0, in: candidate, unmatchedIsError: false)
            }
          )
        } else {
          next.append(
            contentsOf: try matches.map { try fullMatch($0, in: candidate) }
          )
        }
      }
      if index == components.index(before: components.endIndex) {
        return result
      }
      candidates = next
    }
    return []
  }

  public func replace(
    _ content: String,
    pattern: String,
    replacement: String,
    firstOnly: Bool
  ) -> String {
    let expression: NSRegularExpression
    do {
      expression = try compiled(pattern)
    } catch {
      if firstOnly {
        return content.contains(pattern) ? replacement : ""
      }
      return content.replacingOccurrences(of: pattern, with: replacement)
    }
    let range = NSRange(content.startIndex..., in: content)
    if firstOnly {
      guard let match = expression.firstMatch(in: content, range: range) else {
        return ""
      }
      return expression.replacementString(
        for: match,
        in: content,
        offset: 0,
        template: replacement
      )
    }
    return expression.stringByReplacingMatches(
      in: content,
      range: range,
      withTemplate: replacement
    )
  }

  private func regexComponents(_ rawRule: String) -> [String] {
    let normalized =
      rawRule.hasPrefix(":")
      ? String(rawRule.dropFirst())
      : rawRule
    return normalized.components(separatedBy: "&&")
  }

  private func compiled(_ pattern: String) throws -> NSRegularExpression {
    // ICU does not expose Java's UNICODE_CHARACTER_CLASS inline flag with the
    // same surface. The protected Android scenario records this expression as
    // PatternSyntaxException, so it is rejected explicitly.
    guard !pattern.contains("(?U)") else {
      throw SourceRegexBackendError.invalidPattern
    }
    do {
      return try NSRegularExpression(pattern: pattern)
    } catch {
      throw SourceRegexBackendError.invalidPattern
    }
  }

  private func fullMatch(
    _ match: NSTextCheckingResult,
    in content: String
  ) throws -> String {
    guard let range = Range(match.range(at: 0), in: content) else {
      throw SourceRegexBackendError.invalidPattern
    }
    return String(content[range])
  }

  private func captures(
    _ match: NSTextCheckingResult,
    in content: String,
    unmatchedIsError: Bool
  ) throws -> [String] {
    try (0..<match.numberOfRanges).map { index in
      let range = match.range(at: index)
      guard range.location != NSNotFound else {
        if unmatchedIsError {
          throw SourceRegexBackendError.unmatchedGroup
        }
        return ""
      }
      guard let swiftRange = Range(range, in: content) else {
        throw SourceRegexBackendError.invalidPattern
      }
      return String(content[swiftRange])
    }
  }
}

/// Applies Android's `##pattern##replacement[###]` rule form to either the
/// response text or the output of a JSONPath prefix.
public struct SourceRegexReplacementEvaluator: Sendable {
  private struct Rule {
    let prefix: String
    let pattern: String
    let replacement: String
    let firstOnly: Bool
  }

  private let content: String
  private let regex = SourceRegexEvaluator()

  public init(content: String) {
    self.content = content
  }

  public func getString(_ rawRule: String) -> String {
    guard let rule = parse(rawRule) else { return content }
    let input: String
    if rule.prefix.isEmpty {
      input = content
    } else {
      input =
        (try? SourceJSONPathEvaluator(input: .jsonString(content)))?
        .getString(rule.prefix) ?? ""
    }
    return regex.replace(
      input,
      pattern: rule.pattern,
      replacement: rule.replacement,
      firstOnly: rule.firstOnly
    )
  }

  public func getStringList(_ rawRule: String) -> [String] {
    guard let rule = parse(rawRule) else { return [content] }
    let inputs: [String]
    if rule.prefix.isEmpty {
      inputs = [content]
    } else {
      inputs =
        (try? SourceJSONPathEvaluator(input: .jsonString(content)))?
        .getStringList(rule.prefix) ?? []
    }
    return inputs.map {
      regex.replace(
        $0,
        pattern: rule.pattern,
        replacement: rule.replacement,
        firstOnly: rule.firstOnly
      )
    }
  }

  private func parse(_ rawRule: String) -> Rule? {
    guard
      let first = rawRule.range(of: "##"),
      let second = rawRule[first.upperBound...].range(of: "##")
    else {
      return nil
    }
    let prefix = String(rawRule[..<first.lowerBound])
    let pattern = String(rawRule[first.upperBound..<second.lowerBound])
    var replacement = String(rawRule[second.upperBound...])
    let firstOnly = replacement.hasSuffix("###")
    if firstOnly {
      replacement.removeLast(3)
    }
    return Rule(
      prefix: prefix,
      pattern: pattern,
      replacement: replacement,
      firstOnly: firstOnly
    )
  }
}
