import Foundation

public struct SourceURLTemplateInput: Equatable, Sendable {
  public let template: String
  public let key: String?
  public let page: Int?
  public let baseURL: String

  public init(
    template: String,
    key: String? = nil,
    page: Int? = nil,
    baseURL: String
  ) {
    self.template = template
    self.key = key
    self.page = page
    self.baseURL = baseURL
  }
}

public struct SourceURLTemplateCompilation: Equatable, Sendable {
  public let ruleURL: String
  public let logicalURL: String
  public let logicalURLNoQuery: String
  public let queryString: String?
  public let plan: SourceRequestPlan

  public init(
    ruleURL: String,
    logicalURL: String,
    logicalURLNoQuery: String,
    queryString: String?,
    plan: SourceRequestPlan
  ) {
    self.ruleURL = ruleURL
    self.logicalURL = logicalURL
    self.logicalURLNoQuery = logicalURLNoQuery
    self.queryString = queryString
    self.plan = plan
  }
}

public enum SourceURLTemplateCompiler {
  public static func compile(
    _ input: SourceURLTemplateInput
  ) throws -> SourceURLTemplateCompilation {
    let scriptRendered = try renderScriptBlock(
      input.template,
      key: input.key
    )
    let expressionRendered = try renderExpressions(
      scriptRendered,
      key: input.key
    )
    let ruleURL = renderPage(expressionRendered, page: input.page)
    let parts = SourceRequestCompiler.splitURLAndOption(ruleURL)
    let absoluteURL = try resolve(parts.url, baseURL: input.baseURL)
    let rendered =
      parts.option.map { absoluteURL + "," + $0 }
      ?? absoluteURL
    let plan = try SourceRequestCompiler.compileRendered(rendered)
    let queryStart = absoluteURL.firstIndex(of: "?")
    let urlNoQuery =
      queryStart.map { String(absoluteURL[..<$0]) }
      ?? absoluteURL
    let queryString: String?
    if plan.request.method == .get {
      queryString = queryStart.map {
        String(absoluteURL[absoluteURL.index(after: $0)...])
      }
    } else if !plan.formFields.isEmpty,
      let option = parts.option,
      let data = option.data(using: .utf8),
      let body = try? JSONDecoder().decode(
        TemplateOptionBody.self,
        from: data
      ).body
    {
      queryString = body
    } else {
      queryString = nil
    }
    return SourceURLTemplateCompilation(
      ruleURL: ruleURL,
      logicalURL: absoluteURL,
      logicalURLNoQuery: urlNoQuery,
      queryString: queryString,
      plan: plan
    )
  }

  private struct TemplateOptionBody: Decodable {
    let body: String?
  }

  private static func renderScriptBlock(
    _ template: String,
    key: String?
  ) throws -> String {
    let pattern = #"<js>([\s\S]*?)</js>"#
    let regex = try NSRegularExpression(
      pattern: pattern,
      options: [.caseInsensitive]
    )
    let range = NSRange(template.startIndex..., in: template)
    guard let match = regex.firstMatch(in: template, range: range) else {
      if template.range(of: "@js:", options: .caseInsensitive) != nil {
        throw SourceRuntimeIssue(stage: .urlTemplate, code: .invalidURL)
      }
      return template
    }
    guard
      let scriptRange = Range(match.range(at: 1), in: template),
      let wholeRange = Range(match.range, in: template)
    else {
      throw SourceRuntimeIssue(stage: .urlTemplate, code: .invalidURL)
    }
    let result = try evaluate(
      String(template[scriptRange]),
      key: key
    )
    let suffix = String(template[wholeRange.upperBound...])
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let prefix = String(template[..<wholeRange.lowerBound])
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard prefix.isEmpty else {
      throw SourceRuntimeIssue(stage: .urlTemplate, code: .invalidURL)
    }
    return suffix.isEmpty
      ? result
      : suffix.replacingOccurrences(of: "@result", with: result)
  }

  private static func renderExpressions(
    _ template: String,
    key: String?
  ) throws -> String {
    var output = ""
    var cursor = template.startIndex
    while let start = template.range(
      of: "{{",
      range: cursor..<template.endIndex
    ) {
      output += template[cursor..<start.lowerBound]
      guard let end = expressionEnd(in: template, after: start.upperBound) else {
        throw SourceRuntimeIssue(stage: .urlTemplate, code: .invalidURL)
      }
      let expression = String(template[start.upperBound..<end.lowerBound])
        .trimmingCharacters(in: .whitespacesAndNewlines)
      output += try evaluate(expression, key: key)
      cursor = end.upperBound
    }
    output += template[cursor...]
    return output
  }

  private static func expressionEnd(
    in text: String,
    after start: String.Index
  ) -> Range<String.Index>? {
    var cursor = start
    var braceDepth = 0
    while cursor < text.endIndex {
      if text[cursor] == "{" {
        braceDepth += 1
      } else if text[cursor] == "}" {
        let next = text.index(after: cursor)
        if braceDepth == 0,
          next < text.endIndex,
          text[next] == "}"
        {
          return cursor..<text.index(after: next)
        }
        braceDepth = max(0, braceDepth - 1)
      }
      cursor = text.index(after: cursor)
    }
    return nil
  }

  private static func renderPage(_ value: String, page: Int?) -> String {
    guard let page else { return value }
    return value.replacingOccurrences(
      of: #"<([^<>]*)>"#,
      with: { match in
        let values =
          match
          .split(separator: ",", omittingEmptySubsequences: false)
          .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !values.isEmpty else { return "" }
        let index = min(max(page - 1, 0), values.count - 1)
        return values[index]
      }
    )
  }

  private static func evaluate(
    _ expression: String,
    key: String?
  ) throws -> String {
    if expression == "key" {
      return key ?? ""
    }
    if expression == "null" {
      return ""
    }
    if let sum = integerAddition(expression) {
      return String(sum)
    }
    if let returned = integerFunctionReturn(expression) {
      return String(returned)
    }
    if let concatenated = keyConcatenation(expression, key: key) {
      return concatenated
    }
    let ternary =
      #"^key\s*==\s*'([^']*)'\s*\?\s*'([^']*)'\s*:\s*'([^']*)'$"#
    if let captures = captures(ternary, in: expression),
      captures.count == 3
    {
      return key == captures[0] ? captures[1] : captures[2]
    }
    throw SourceRuntimeIssue(stage: .urlTemplate, code: .invalidURL)
  }

  private static func integerAddition(_ expression: String) -> Int? {
    guard
      let values = captures(#"^(\d+)\s*\+\s*(\d+)$"#, in: expression),
      values.count == 2,
      let lhs = Int(values[0]),
      let rhs = Int(values[1])
    else {
      return nil
    }
    return lhs + rhs
  }

  private static func integerFunctionReturn(_ expression: String) -> Int? {
    guard
      let values = captures(
        #"^\(function\(\)\{\s*return\s+(\d+);\s*\}\)\(\)$"#,
        in: expression
      ),
      values.count == 1
    else {
      return nil
    }
    return Int(values[0])
  }

  private static func keyConcatenation(
    _ expression: String,
    key: String?
  ) -> String? {
    guard
      let values = captures(
        #"^'([^']*)'\s*\+\s*key$"#,
        in: expression
      ),
      values.count == 1
    else {
      return nil
    }
    return values[0] + (key ?? "")
  }

  private static func captures(
    _ pattern: String,
    in value: String
  ) -> [String]? {
    guard
      let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(
        in: value,
        range: NSRange(value.startIndex..., in: value)
      ),
      match.range == NSRange(value.startIndex..., in: value)
    else {
      return nil
    }
    return (1..<match.numberOfRanges).compactMap { index in
      Range(match.range(at: index), in: value).map { String(value[$0]) }
    }
  }

  private static func resolve(
    _ value: String,
    baseURL: String
  ) throws -> String {
    if URL(string: value)?.scheme != nil {
      return value
    }
    guard
      let base = URL(string: baseURL),
      let resolved = URL(string: value, relativeTo: base)?.absoluteURL
    else {
      throw SourceRuntimeIssue(stage: .urlTemplate, code: .invalidURL)
    }
    return resolved.absoluteString.removingPercentEncoding
      ?? resolved.absoluteString
  }
}

extension String {
  fileprivate func replacingOccurrences(
    of pattern: String,
    with replacement: (String) -> String
  ) -> String {
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
      return self
    }
    var result = self
    for match in regex.matches(
      in: self,
      range: NSRange(startIndex..., in: self)
    ).reversed() {
      guard
        let range = Range(match.range, in: self),
        let capture = Range(match.range(at: 1), in: self)
      else {
        continue
      }
      result.replaceSubrange(range, with: replacement(String(self[capture])))
    }
    return result
  }
}
