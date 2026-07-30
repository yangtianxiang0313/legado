import Testing
@testable import ReaderCore

@Suite("Reader content normalization")
struct ReaderContentNormalizationTests {
  @Test("normalizes title and paragraph projection")
  func plainProjection() {
    let result = normalize(
      title: "第1章\r\n开始",
      content: "  第一段  \n\n　第二段　\n",
      includeTitle: true,
      indent: ">>"
    )
    #expect(result.displayTitle == "第1章开始")
    #expect(result.paragraphs == ["第1章开始", ">>第一段", ">>第二段"])
  }

  @Test("applies content rules in order and reports effective rules")
  func orderedRules() {
    let result = normalize(
      content: "alpha beta alpha",
      indent: ">",
      rules: [
        rule("one", "alpha", "beta", order: 10),
        rule("two", "beta", "final", order: 20),
        rule("unused", "absent", "ignored", order: 30),
      ]
    )
    #expect(result.renderedText == ">final final final")
    #expect(result.effectiveRuleNames == ["one", "two"])
  }

  @Test("book setting disables title and content rules")
  func replacementDisabled() {
    let result = normalize(
      title: "旧\r标题",
      content: "old body",
      includeTitle: true,
      useRules: false,
      indent: ">",
      rules: [
        rule(
          "title",
          "旧标题",
          "新标题",
          title: true,
          content: false
        ),
        rule("body", "old", "new"),
      ]
    )
    #expect(result.renderedText == "旧标题\n>old body")
    #expect(result.effectiveRuleNames.isEmpty)
  }

  @Test("removes matching title with flexible spaces")
  func removesRawTitle() {
    let result = normalize(
      bookName: "测试书",
      title: "第 2 章 标题",
      content: "测试书：第 2 章 标题\n正文",
      indent: ">"
    )
    #expect(result.sameTitleRemoved)
    #expect(result.renderedText == ">正文")
  }

  @Test("uses content rules for duplicate-title fallback")
  func removesReplacedTitle() {
    let result = normalize(
      title: "第3章",
      content: "第三章\n内容",
      indent: ">",
      rules: [rule("shape", "第3章", "第三章")]
    )
    #expect(result.sameTitleRemoved)
    #expect(result.renderedText == ">内容")
    #expect(result.effectiveRuleNames.isEmpty)
  }

  @Test("filters disabled, scoped and excluded rules")
  func filtersRules() {
    let result = normalize(
      bookName: "目标书",
      origin: "target",
      content: "seed",
      indent: ">",
      rules: [
        rule("match", "seed", "accepted", scope: "目标书"),
        rule("wrong", "accepted", "wrong", scope: "另一书"),
        rule("disabled", "accepted", "disabled", enabled: false),
        rule("excluded", "accepted", "excluded", exclude: "target"),
      ]
    )
    #expect(result.renderedText == ">accepted")
    #expect(result.effectiveRuleNames == ["match"])
  }

  private func normalize(
    bookName: String = "书",
    origin: String = "origin",
    title: String = "标题",
    content: String,
    includeTitle: Bool = false,
    useRules: Bool = true,
    indent: String,
    rules: [ReaderContentReplacementRule] = []
  ) -> ReaderContentNormalizationResult {
    AndroidReaderContentNormalizationPolicy.normalize(
      ReaderContentNormalizationInput(
        bookName: bookName,
        bookOrigin: origin,
        chapterTitle: title,
        content: content,
        includeTitle: includeTitle,
        useReplacementRules: useRules,
        paragraphIndent: indent,
        rules: rules
      )
    )
  }

  private func rule(
    _ name: String,
    _ pattern: String,
    _ replacement: String,
    scope: String? = nil,
    exclude: String? = nil,
    title: Bool = false,
    content: Bool = true,
    enabled: Bool = true,
    order: Int = 0
  ) -> ReaderContentReplacementRule {
    ReaderContentReplacementRule(
      name: name,
      pattern: pattern,
      replacement: replacement,
      scope: scope,
      excludeScope: exclude,
      appliesToTitle: title,
      appliesToContent: content,
      isEnabled: enabled,
      isRegex: false,
      order: order
    )
  }
}
