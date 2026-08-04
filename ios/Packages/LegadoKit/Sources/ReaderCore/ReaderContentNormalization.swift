import Foundation

public struct ReaderContentReplacementRule: Equatable, Sendable {
  public let name: String
  public let pattern: String
  public let replacement: String
  public let scope: String?
  public let excludeScope: String?
  public let appliesToTitle: Bool
  public let appliesToContent: Bool
  public let isEnabled: Bool
  public let isRegex: Bool
  public let order: Int

  public init(
    name: String,
    pattern: String,
    replacement: String,
    scope: String? = nil,
    excludeScope: String? = nil,
    appliesToTitle: Bool = false,
    appliesToContent: Bool = true,
    isEnabled: Bool = true,
    isRegex: Bool = true,
    order: Int = 0
  ) {
    self.name = name
    self.pattern = pattern
    self.replacement = replacement
    self.scope = scope
    self.excludeScope = excludeScope
    self.appliesToTitle = appliesToTitle
    self.appliesToContent = appliesToContent
    self.isEnabled = isEnabled
    self.isRegex = isRegex
    self.order = order
  }
}

public struct ReaderContentNormalizationInput: Equatable, Sendable {
  public let bookName: String
  public let bookOrigin: String
  public let chapterTitle: String
  public let content: String
  public let includeTitle: Bool
  public let useReplacementRules: Bool
  public let resegmentContent: Bool
  public let paragraphIndent: String
  public let rules: [ReaderContentReplacementRule]

  public init(
    bookName: String,
    bookOrigin: String,
    chapterTitle: String,
    content: String,
    includeTitle: Bool,
    useReplacementRules: Bool,
    resegmentContent: Bool = false,
    paragraphIndent: String,
    rules: [ReaderContentReplacementRule]
  ) {
    self.bookName = bookName
    self.bookOrigin = bookOrigin
    self.chapterTitle = chapterTitle
    self.content = content
    self.includeTitle = includeTitle
    self.useReplacementRules = useReplacementRules
    self.resegmentContent = resegmentContent
    self.paragraphIndent = paragraphIndent
    self.rules = rules
  }
}

public struct ReaderContentNormalizationResult: Equatable, Sendable {
  public let displayTitle: String
  public let sameTitleRemoved: Bool
  public let paragraphs: [String]
  public let effectiveRuleNames: [String]

  public init(
    displayTitle: String,
    sameTitleRemoved: Bool,
    paragraphs: [String],
    effectiveRuleNames: [String]
  ) {
    self.displayTitle = displayTitle
    self.sameTitleRemoved = sameTitleRemoved
    self.paragraphs = paragraphs
    self.effectiveRuleNames = effectiveRuleNames
  }

  public var renderedText: String {
    paragraphs.joined(separator: "\n")
  }
}

public enum AndroidReaderContentNormalizationPolicy {
  public static func normalize(
    _ input: ReaderContentNormalizationInput
  ) -> ReaderContentNormalizationResult {
    let selected = selectedRules(for: input)
    let titleRules = selected.filter(\.appliesToTitle)
    let contentRules = selected.filter(\.appliesToContent)
    let displayTitle = normalizedTitle(
      input.chapterTitle,
      rules: titleRules,
      useReplacementRules: input.useReplacementRules
    )

    var content = input.content
    var sameTitleRemoved = false
    var effectiveRules: [String] = []
    if content != "null" {
      if let remainder = removingTitlePrefix(
        from: content,
        bookName: input.bookName,
        titlePattern: flexibleTitlePattern(input.chapterTitle)
      ) {
        content = remainder
        sameTitleRemoved = true
      } else if input.useReplacementRules {
        let replacementTitle = normalizedTitle(
          input.chapterTitle,
          rules: contentRules,
          useReplacementRules: true
        )
        if let remainder = removingTitlePrefix(
          from: content,
          bookName: input.bookName,
          titlePattern: NSRegularExpression.escapedPattern(
            for: replacementTitle
          )
        ) {
          content = remainder
          sameTitleRemoved = true
        }
      }

      if input.resegmentContent {
        content = AndroidContentResegment.resegment(
          content,
          chapterName: input.chapterTitle
        )
      }

      if input.useReplacementRules {
        content = content
          .components(separatedBy: "\n")
          .map { $0.trimmingCharacters(in: .whitespaces) }
          .joined(separator: "\n")
        for rule in contentRules where !rule.pattern.isEmpty {
          guard let replaced = replacing(content, with: rule) else {
            continue
          }
          if replaced != content {
            effectiveRules.append(rule.name)
            content = replaced
          }
        }
      }
    }

    if input.includeTitle {
      content = displayTitle + "\n" + content
    }
    var paragraphs: [String] = []
    for raw in content.components(separatedBy: "\n") {
      let paragraph = trimAndroidParagraph(raw)
      guard !paragraph.isEmpty else { continue }
      if paragraphs.isEmpty && input.includeTitle {
        paragraphs.append(paragraph)
      } else {
        paragraphs.append(input.paragraphIndent + paragraph)
      }
    }
    return ReaderContentNormalizationResult(
      displayTitle: displayTitle,
      sameTitleRemoved: sameTitleRemoved,
      paragraphs: paragraphs,
      effectiveRuleNames: effectiveRules
    )
  }

  private static func selectedRules(
    for input: ReaderContentNormalizationInput
  ) -> [ReaderContentReplacementRule] {
    input.rules
      .filter { rule in
        guard rule.isEnabled else { return false }
        let included =
          rule.scope == nil
          || rule.scope?.trimmingCharacters(in: .whitespaces).isEmpty == true
          || rule.scope?.contains(input.bookName) == true
          || rule.scope?.contains(input.bookOrigin) == true
        let excluded =
          rule.excludeScope?.contains(input.bookName) == true
          || rule.excludeScope?.contains(input.bookOrigin) == true
        return included && !excluded
      }
      .sorted {
        if $0.order == $1.order { return $0.name < $1.name }
        return $0.order < $1.order
      }
  }

  private static func normalizedTitle(
    _ title: String,
    rules: [ReaderContentReplacementRule],
    useReplacementRules: Bool
  ) -> String {
    var value = title.replacingOccurrences(
      of: "[\\r\\n]",
      with: "",
      options: .regularExpression
    )
    guard useReplacementRules else { return value }
    for rule in rules where !rule.pattern.isEmpty {
      guard
        let candidate = replacing(value, with: rule),
        !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        continue
      }
      value = candidate
    }
    return value
  }

  private static func replacing(
    _ value: String,
    with rule: ReaderContentReplacementRule
  ) -> String? {
    if !rule.isRegex {
      return value.replacingOccurrences(
        of: rule.pattern,
        with: rule.replacement
      )
    }
    guard
      let expression = try? NSRegularExpression(pattern: rule.pattern)
    else {
      return nil
    }
    return expression.stringByReplacingMatches(
      in: value,
      range: NSRange(value.startIndex..., in: value),
      withTemplate: rule.replacement
    )
  }

  private static func flexibleTitlePattern(_ title: String) -> String {
    var result = ""
    var literal = ""
    func flushLiteral() {
      guard !literal.isEmpty else { return }
      result += NSRegularExpression.escapedPattern(for: literal)
      literal.removeAll(keepingCapacity: true)
    }
    for character in title {
      if character.isWhitespace {
        flushLiteral()
        result += "\\s*"
      } else {
        literal.append(character)
      }
    }
    flushLiteral()
    return result
  }

  private static func removingTitlePrefix(
    from content: String,
    bookName: String,
    titlePattern: String
  ) -> String? {
    let bookPattern = NSRegularExpression.escapedPattern(for: bookName)
    let pattern =
      "^(?:\\s|\\p{P}|\(bookPattern))*\(titlePattern)(?:\\s)*"
    guard
      let expression = try? NSRegularExpression(pattern: pattern),
      let match = expression.firstMatch(
        in: content,
        range: NSRange(content.startIndex..., in: content)
      ),
      match.range.location == 0,
      let range = Range(match.range, in: content)
    else {
      return nil
    }
    return String(content[range.upperBound...])
  }

  private static func trimAndroidParagraph(_ value: String) -> String {
    func shouldTrim(_ character: Character) -> Bool {
      character.unicodeScalars.allSatisfy {
        $0.value <= 0x20 || $0.value == 0x3000
      }
    }
    return String(
      value.drop(while: shouldTrim).reversed()
        .drop(while: shouldTrim).reversed()
    )
  }
}
