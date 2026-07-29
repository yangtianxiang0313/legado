import Foundation
import LegadoCore

public enum SourceRuleBackend: String, Sendable, Equatable {
  case defaultBackend = "default"
  case xpath
  case json
  case regex
  case javaScript = "js"
}

public struct SourceRuleDescriptor: Sendable, Equatable {
  public let mode: SourceRuleBackend
  public let rule: String

  public init(mode: SourceRuleBackend, rule: String) {
    self.mode = mode
    self.rule = rule
  }
}

public struct SourceRuleEvaluation: Sendable, Equatable {
  public let descriptor: SourceRuleDescriptor
  public let value: JSONValue

  public init(descriptor: SourceRuleDescriptor, value: JSONValue) {
    self.descriptor = descriptor
    self.value = value
  }
}

public struct SourceParserCacheIdentity: RawRepresentable, Sendable, Equatable {
  public let rawValue: UInt64

  public init(rawValue: UInt64) {
    self.rawValue = rawValue
  }
}

public enum SourceRuleRuntimeError: Error, Sendable, Equatable {
  case missingContent
  case malformedContent(SourceRuleBackend)
  case unsupportedRule(SourceRuleBackend, String)
}

/// Stateful, UI-independent compatibility evaluator for one AnalyzeRule
/// lifecycle. Its mutable mode and parser caches deliberately belong to this
/// instance; callers create a new evaluator for an independent pipeline.
public final class SourceRuleEvaluator {
  private final class CacheBox<Value> {
    let identity: SourceParserCacheIdentity
    let value: Value

    init(identity: SourceParserCacheIdentity, value: Value) {
      self.identity = identity
      self.value = value
    }
  }

  private struct ParsedRule {
    let descriptor: SourceRuleDescriptor
    let executionRule: String
  }

  private enum JSONPathStep {
    case field(String)
    case index(Int)
    case wildcard
  }

  private let lock = NSRecursiveLock()
  private var content: String?
  private var regexModeIsSticky = false
  private var nextCacheIdentity: UInt64 = 0
  private var htmlCache: CacheBox<HTMLDocument>?
  private var xpathCache: CacheBox<HTMLDocument>?
  private var jsonCache: CacheBox<JSONValue>?

  public init(content: String? = nil) {
    self.content = content
  }

  public func setContent(_ content: String?) throws {
    try locked {
      guard let content else {
        throw SourceRuleRuntimeError.missingContent
      }
      guard self.content != content else { return }
      self.content = content
      htmlCache = nil
      xpathCache = nil
      jsonCache = nil
    }
  }

  public func evaluate(_ rule: String) throws -> SourceRuleEvaluation {
    try locked {
      guard let content else {
        throw SourceRuleRuntimeError.missingContent
      }
      return try evaluate(rule, content: content, usesCurrentCache: true)
    }
  }

  /// Evaluates temporary content without changing the current content or any
  /// parser cache. This mirrors AnalyzeRule's mContent isolation boundary.
  public func evaluate(
    _ rule: String,
    against foreignContent: String
  ) throws -> SourceRuleEvaluation {
    try locked {
      try evaluate(
        rule,
        content: foreignContent,
        usesCurrentCache: false
      )
    }
  }

  /// Native script objects short-circuit string parser backends. The mode is
  /// still projected as JSON-compatible metadata, matching Android's
  /// diagnostic SourceRule projection without routing through JSONPath.
  public func evaluate(
    _ rule: String,
    nativeObject: [String: JSONValue]
  ) -> SourceRuleEvaluation {
    locked {
      SourceRuleEvaluation(
        descriptor: SourceRuleDescriptor(mode: .json, rule: rule),
        value: nativeObject[rule] ?? .null
      )
    }
  }

  public func cacheIdentity(
    for backend: SourceRuleBackend
  ) -> SourceParserCacheIdentity? {
    locked {
      switch backend {
      case .defaultBackend:
        htmlCache?.identity
      case .xpath:
        xpathCache?.identity
      case .json:
        jsonCache?.identity
      case .regex, .javaScript:
        nil
      }
    }
  }

  private func evaluate(
    _ rule: String,
    content: String,
    usesCurrentCache: Bool
  ) throws -> SourceRuleEvaluation {
    let parsed = parse(rule, content: content)
    let value: JSONValue
    switch parsed.descriptor.mode {
    case .defaultBackend:
      value = try evaluateCSS(
        parsed.executionRule,
        content: content,
        usesCurrentCache: usesCurrentCache
      )
    case .xpath:
      value = try evaluateXPath(
        parsed.executionRule,
        content: content,
        usesCurrentCache: usesCurrentCache
      )
    case .json:
      value = try evaluateJSON(
        parsed.executionRule,
        content: content,
        usesCurrentCache: usesCurrentCache
      )
    case .regex:
      value = try evaluateRegex(parsed.executionRule, content: content)
    case .javaScript:
      value = try evaluateJavaScript(
        parsed.executionRule,
        result: content
      )
    }
    return SourceRuleEvaluation(
      descriptor: parsed.descriptor,
      value: value
    )
  }

  private func parse(_ rawRule: String, content: String) -> ParsedRule {
    if regexModeIsSticky {
      let normalized =
        rawRule.hasPrefix(":") ? String(rawRule.dropFirst()) : rawRule
      return ParsedRule(
        descriptor: SourceRuleDescriptor(mode: .regex, rule: normalized),
        executionRule: normalized
      )
    }
    if rawRule.hasPrefix(":") {
      regexModeIsSticky = true
      let normalized = String(rawRule.dropFirst())
      return ParsedRule(
        descriptor: SourceRuleDescriptor(mode: .regex, rule: normalized),
        executionRule: normalized
      )
    }
    if rawRule.hasPrefix("@@") {
      let normalized = String(rawRule.dropFirst(2))
      return ParsedRule(
        descriptor: SourceRuleDescriptor(
          mode: .defaultBackend,
          rule: normalized
        ),
        executionRule: normalized
      )
    }
    if let normalized = removingPrefix("@XPath:", from: rawRule) {
      return ParsedRule(
        descriptor: SourceRuleDescriptor(mode: .xpath, rule: normalized),
        executionRule: normalized
      )
    }
    if rawRule.hasPrefix("//") {
      return ParsedRule(
        descriptor: SourceRuleDescriptor(mode: .xpath, rule: rawRule),
        executionRule: rawRule
      )
    }
    if let normalized = removingPrefix("@Json:", from: rawRule) {
      return ParsedRule(
        descriptor: SourceRuleDescriptor(mode: .json, rule: normalized),
        executionRule: normalized
      )
    }
    if rawRule.hasPrefix("<js>"), rawRule.hasSuffix("</js>") {
      let normalized = String(rawRule.dropFirst(4).dropLast(5))
      return ParsedRule(
        descriptor: SourceRuleDescriptor(
          mode: .javaScript,
          rule: normalized
        ),
        executionRule: normalized
      )
    }
    if let normalized = removingPrefix("@js:", from: rawRule) {
      return ParsedRule(
        descriptor: SourceRuleDescriptor(
          mode: .javaScript,
          rule: normalized
        ),
        executionRule: normalized
      )
    }
    if let normalized = removingPrefix("@CSS:", from: rawRule) {
      return ParsedRule(
        descriptor: SourceRuleDescriptor(
          mode: .defaultBackend,
          rule: rawRule
        ),
        executionRule: normalized
      )
    }
    if rawRule.hasPrefix("$") || isJSON(content) {
      return ParsedRule(
        descriptor: SourceRuleDescriptor(mode: .json, rule: rawRule),
        executionRule: rawRule
      )
    }
    return ParsedRule(
      descriptor: SourceRuleDescriptor(
        mode: .defaultBackend,
        rule: rawRule
      ),
      executionRule: rawRule
    )
  }

  private func evaluateCSS(
    _ rawRule: String,
    content: String,
    usesCurrentCache: Bool
  ) throws -> JSONValue {
    let selector: String
    if rawRule.lowercased().hasSuffix("@text") {
      selector = String(rawRule.dropLast(5))
    } else {
      selector = rawRule
    }
    let document: HTMLDocument
    do {
      if usesCurrentCache {
        if let htmlCache {
          document = htmlCache.value
        } else {
          let parsed = try HTMLDocument(html: content)
          let box = CacheBox(identity: makeCacheIdentity(), value: parsed)
          htmlCache = box
          document = box.value
        }
      } else {
        document = try HTMLDocument(html: content)
      }
      guard let first = try document.select(selector).first else {
        return .null
      }
      return .string(first.normalizedText)
    } catch let error as SourceRuleRuntimeError {
      throw error
    } catch {
      throw SourceRuleRuntimeError.malformedContent(.defaultBackend)
    }
  }

  private func evaluateXPath(
    _ rule: String,
    content: String,
    usesCurrentCache: Bool
  ) throws -> JSONValue {
    let pattern = #"^//([A-Za-z][A-Za-z0-9_-]*)/text\(\)$"#
    guard
      let expression = try? NSRegularExpression(pattern: pattern),
      let match = expression.firstMatch(
        in: rule,
        range: NSRange(rule.startIndex..., in: rule)
      ),
      let tagRange = Range(match.range(at: 1), in: rule)
    else {
      throw SourceRuleRuntimeError.unsupportedRule(.xpath, rule)
    }
    let document: HTMLDocument
    do {
      if usesCurrentCache {
        if let xpathCache {
          document = xpathCache.value
        } else {
          let parsed = try HTMLDocument(html: content)
          let box = CacheBox(identity: makeCacheIdentity(), value: parsed)
          xpathCache = box
          document = box.value
        }
      } else {
        document = try HTMLDocument(html: content)
      }
      guard let first = try document.select(String(rule[tagRange])).first else {
        return .null
      }
      return .string(first.normalizedText)
    } catch let error as SourceRuleRuntimeError {
      throw error
    } catch {
      throw SourceRuleRuntimeError.malformedContent(.xpath)
    }
  }

  private func evaluateJSON(
    _ rule: String,
    content: String,
    usesCurrentCache: Bool
  ) throws -> JSONValue {
    let root: JSONValue
    do {
      if usesCurrentCache {
        if let jsonCache {
          root = jsonCache.value
        } else {
          let parsed = try JSONValueCodec.decode(Data(content.utf8))
          let box = CacheBox(identity: makeCacheIdentity(), value: parsed)
          jsonCache = box
          root = box.value
        }
      } else {
        root = try JSONValueCodec.decode(Data(content.utf8))
      }
    } catch {
      throw SourceRuleRuntimeError.malformedContent(.json)
    }
    let steps = try jsonPathSteps(rule)
    var values = [root]
    for step in steps {
      switch step {
      case .field(let name):
        values = values.compactMap { value in
          guard case .object(let object) = value else { return nil }
          return object[name]
        }
      case .index(let index):
        values = values.compactMap { value in
          guard
            case .array(let array) = value,
            array.indices.contains(index)
          else { return nil }
          return array[index]
        }
      case .wildcard:
        values = values.flatMap { value -> [JSONValue] in
          guard case .array(let array) = value else { return [] }
          return array
        }
      }
    }
    if values.count == 1 {
      return values[0]
    }
    return .array(values)
  }

  private func jsonPathSteps(_ rawRule: String) throws -> [JSONPathStep] {
    var rule = rawRule
    if rule.hasPrefix("$") {
      rule.removeFirst()
    }
    if rule.hasPrefix(".") {
      rule.removeFirst()
    }
    var steps: [JSONPathStep] = []
    var field = ""
    var index = rule.startIndex
    func appendField() {
      guard !field.isEmpty else { return }
      steps.append(.field(field))
      field = ""
    }
    while index < rule.endIndex {
      let character = rule[index]
      if character == "." {
        appendField()
        index = rule.index(after: index)
      } else if character == "[" {
        appendField()
        guard let end = rule[index...].firstIndex(of: "]") else {
          throw SourceRuleRuntimeError.unsupportedRule(.json, rawRule)
        }
        let token = String(rule[rule.index(after: index)..<end])
        if token == "*" {
          steps.append(.wildcard)
        } else if let value = Int(token), value >= 0 {
          steps.append(.index(value))
        } else {
          throw SourceRuleRuntimeError.unsupportedRule(.json, rawRule)
        }
        index = rule.index(after: end)
      } else {
        field.append(character)
        index = rule.index(after: index)
      }
    }
    appendField()
    guard !steps.isEmpty else {
      throw SourceRuleRuntimeError.unsupportedRule(.json, rawRule)
    }
    return steps
  }

  private func evaluateRegex(
    _ rule: String,
    content: String
  ) throws -> JSONValue {
    let expression: NSRegularExpression
    do {
      expression = try NSRegularExpression(pattern: rule)
    } catch {
      throw SourceRuleRuntimeError.unsupportedRule(.regex, rule)
    }
    let matches = expression.matches(
      in: content,
      range: NSRange(content.startIndex..., in: content)
    )
    return .array(
      matches.map { match in
        .array(
          (0..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            guard
              range.location != NSNotFound,
              let swiftRange = Range(range, in: content)
            else { return .string("") }
            return .string(String(content[swiftRange]))
          }
        )
      }
    )
  }

  private func evaluateJavaScript(
    _ rule: String,
    result: String
  ) throws -> JSONValue {
    guard let plus = rule.firstIndex(of: "+") else {
      throw SourceRuleRuntimeError.unsupportedRule(.javaScript, rule)
    }
    let left = rule[..<plus].trimmingCharacters(in: .whitespaces)
    let right = rule[rule.index(after: plus)...]
      .trimmingCharacters(in: .whitespaces)
    guard
      left == "result.toString()",
      right.count >= 2,
      let quote = right.first,
      (quote == "'" || quote == "\""),
      right.last == quote
    else {
      throw SourceRuleRuntimeError.unsupportedRule(.javaScript, rule)
    }
    return .string(result + right.dropFirst().dropLast())
  }

  private func isJSON(_ content: String) -> Bool {
    (try? JSONValueCodec.decode(Data(content.utf8))) != nil
  }

  private func removingPrefix(
    _ prefix: String,
    from value: String
  ) -> String? {
    guard value.lowercased().hasPrefix(prefix.lowercased()) else {
      return nil
    }
    return String(value.dropFirst(prefix.count))
  }

  private func makeCacheIdentity() -> SourceParserCacheIdentity {
    nextCacheIdentity += 1
    return SourceParserCacheIdentity(rawValue: nextCacheIdentity)
  }

  private func locked<T>(_ operation: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try operation()
  }
}
