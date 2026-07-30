import Foundation
import LegadoCore

struct SourceBookListParser {
  let definition: SourceSearchDefinition
  let variableStore: SourceVariableStore

  func parse(
    response: SourceSearchResponse,
    rules: SearchRules,
    reverse: Bool,
    allowsDetailPattern: Bool
  ) async throws -> [SourceSearchBook] {
    if usesStructuredRules(response: response, rules: rules) {
      return try await parseStructured(
        response: response,
        rules: rules,
        reverse: reverse
      )
    }
    let document: HTMLDocument
    do {
      document = try HTMLDocument(html: response.body)
    } catch {
      throw SourceRuntimeIssue(stage: .parsing, code: .malformedHTML)
    }

    if allowsDetailPattern, try matchesDetailPattern(response.url) {
      guard
        let book = try await book(
          node: document.root,
          document: document,
          response: response,
          rules: detailRules(),
          fallbackBookURL:
            response.url.removingPercentEncoding ?? response.url,
          preservesHTML: true
        )
      else {
        throw SourceRuntimeIssue(
          stage: .fieldEvaluation,
          code: .ruleFailed
        )
      }
      return [book]
    }

    let listPlan = SourceVariableRulePlan.parse(
      normalizedList(rules.list)
    )
    try await applyWrites(
      listPlan.writes,
      node: document.root,
      document: document,
      resolver: sharedResolver
    )
    let nodes = try document.select(
      HTMLCSSRule(listPlan.executionRule).cssSelector
    )
    if nodes.isEmpty, definition.bookURLPattern?.isEmpty != false {
      if let detail = try await book(
        node: document.root,
        document: document,
        response: response,
        rules: detailRules(),
        fallbackBookURL: response.url,
        preservesHTML: true
      ) {
        return [detail]
      }
      return []
    }

    var seen: Set<String> = []
    var books: [SourceSearchBook] = []
    for node in nodes {
      guard
        let candidate = try await book(
          node: node,
          document: document,
          response: response,
          rules: listRules(rules),
          fallbackBookURL: response.url,
          preservesHTML: false
        ),
        seen.insert(candidate.bookURL).inserted
      else {
        continue
      }
      books.append(candidate)
    }
    return reverse ? Array(books.reversed()) : books
  }

  private struct Rules {
    let name: HTMLCSSRule
    let author: HTMLCSSRule
    let kind: HTMLCSSRule
    let wordCount: HTMLCSSRule
    let intro: HTMLCSSRule
    let lastChapter: HTMLCSSRule
    let bookURL: HTMLCSSRule?
    let coverURL: HTMLCSSRule
  }

  private func listRules(_ rules: SearchRules) -> Rules {
    Rules(
      name: rules.name,
      author: rules.author,
      kind: rules.kind,
      wordCount: rules.wordCount,
      intro: rules.intro,
      lastChapter: rules.lastChapter,
      bookURL: rules.bookURL,
      coverURL: rules.coverURL
    )
  }

  private func detailRules() -> Rules {
    let rules = definition.runtime.bookInfo
    return Rules(
      name: rules.name,
      author: rules.author,
      kind: rules.kind,
      wordCount: rules.wordCount,
      intro: rules.intro,
      lastChapter: rules.lastChapter,
      bookURL: nil,
      coverURL: rules.coverURL
    )
  }

  private func normalizedList(_ value: String) -> String {
    guard value.first == "-" || value.first == "+" else {
      return value
    }
    return String(value.dropFirst())
  }

  private func book(
    node: HTMLNode,
    document: HTMLDocument,
    response: SourceSearchResponse,
    rules: Rules,
    fallbackBookURL: String,
    preservesHTML: Bool
  ) async throws -> SourceSearchBook? {
    let store = SourceVariableStore(
      policy: .androidRuleData,
      values: await variableStore.snapshot()
    )
    let resolver = SourceVariableResolver(
      role: .rule,
      scopes: SourceVariableScopes(
        book: store,
        ruleData: store
      )
    )
    let name =
      try await variableValue(
        rules.name,
        in: node,
        document: document,
        resolver: resolver
      ) ?? ""
    guard !name.isEmpty else { return nil }
    let rawBookURL: String?
    if let bookURLRule = rules.bookURL {
      rawBookURL = try await variableValue(
        bookURLRule,
        in: node,
        document: document,
        resolver: resolver
      )
    } else {
      rawBookURL = nil
    }
    let resolvedBookEndpoint = rawBookURL.flatMap {
      resolveEndpoint($0, relativeTo: response.url)
    }
    guard let bookEndpoint =
      resolvedBookEndpoint
        ?? resolveEndpoint(
          fallbackBookURL,
          relativeTo: response.url
        )
    else {
      return nil
    }
    let bookURL = bookEndpoint.logicalURL.absoluteString
    let coverURL = try await variableValue(
      rules.coverURL,
      in: node,
      document: document,
      resolver: resolver
    ).map {
      resolve($0, relativeTo: response.url)
    }
    return SourceSearchBook(
      name: name,
      author: normalizeAuthor(
        try await variableValue(
          rules.author,
          in: node,
          document: document,
          resolver: resolver
        ) ?? ""
      ),
      kind: try await variableValue(
        rules.kind,
        in: node,
        document: document,
        resolver: resolver
      ) ?? "",
      wordCount: normalizeWordCount(
        try await variableValue(
          rules.wordCount,
          in: node,
          document: document,
          resolver: resolver
        ) ?? ""
      ),
      intro: try await variableValue(
        rules.intro,
        in: node,
        document: document,
        resolver: resolver
      ) ?? "",
      lastChapter:
        try await variableValue(
          rules.lastChapter,
          in: node,
          document: document,
          resolver: resolver
        ) ?? "",
      bookURL: bookURL,
      bookRequestExpression: bookEndpoint.requestExpression,
      coverURL: coverURL,
      origin: definition.sourceURL,
      originName: definition.sourceName,
      originOrder: definition.originOrder,
      infoHTML:
        preservesHTML || bookURL == response.url
        ? response.body
        : nil,
      variables: await store.snapshot()
    )
  }

  private var sharedResolver: SourceVariableResolver {
    SourceVariableResolver(
      role: .rule,
      scopes: SourceVariableScopes(ruleData: variableStore)
    )
  }

  private func value(
    _ rule: HTMLCSSRule,
    in node: HTMLNode,
    document: HTMLDocument
  ) throws -> String? {
    guard
      let match = try document.select(
        rule.cssSelector,
        within: node
      ).first
    else {
      return nil
    }
    let raw: String?
    switch rule.value {
    case .text, .html:
      raw = match.normalizedText
    case .href:
      raw = match.attributes["href"]
    case .src:
      raw = match.attributes["src"]
    }
    let trimmed = raw?.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    return trimmed?.isEmpty == false ? trimmed : nil
  }

  private func variableValue(
    _ rule: HTMLCSSRule,
    in node: HTMLNode,
    document: HTMLDocument,
    resolver: SourceVariableResolver
  ) async throws -> String? {
    let plan = SourceVariableRulePlan.parse(rule.selector)
    try await applyWrites(
      plan.writes,
      node: node,
      document: document,
      resolver: resolver
    )
    guard !plan.executionRule.isEmpty else { return nil }
    if
      plan.executionRule.lowercased().hasPrefix("@js:")
        || plan.executionRule.lowercased().hasPrefix("<js>")
    {
      let result = try await SourceVariableRuleEvaluator(
        content: node.normalizedText,
        resolver: resolver
      ).getString(plan.executionRule)
      return result.isEmpty ? nil : result
    }
    return try value(
      HTMLCSSRule(
        plan.executionRule,
        value: rule.value
      ),
      in: node,
      document: document
    )
  }

  private func applyWrites(
    _ writes: [String: String],
    node: HTMLNode,
    document: HTMLDocument,
    resolver: SourceVariableResolver
  ) async throws {
    for key in writes.keys.sorted() {
      let rule = HTMLCSSRule(writes[key] ?? "")
      let value =
        try await variableValue(
          rule,
          in: node,
          document: document,
          resolver: resolver
        ) ?? ""
      _ = await resolver.put(key, value: value)
    }
  }

  private func matchesDetailPattern(_ url: String) throws -> Bool {
    guard
      let pattern = definition.bookURLPattern?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !pattern.isEmpty
    else {
      return false
    }
    do {
      let regex = try NSRegularExpression(pattern: pattern)
      return regex.firstMatch(
        in: url,
        range: NSRange(url.startIndex..., in: url)
      ) != nil
    } catch {
      throw SourceRuntimeIssue(
        stage: .fieldEvaluation,
        code: .ruleFailed
      )
    }
  }

  private func normalizeAuthor(_ value: String) -> String {
    value.replacingOccurrences(
      of: #"^\s*作者[：:]\s*"#,
      with: "",
      options: .regularExpression
    )
  }

  private func normalizeWordCount(_ value: String) -> String {
    guard !value.isEmpty else { return "" }
    if value.range(
      of: #"^\d+(?:\.\d+)?万字$"#,
      options: .regularExpression
    ) != nil {
      return value
    }
    guard let count = Double(value), count >= 10_000 else {
      return value
    }
    let tenThousands = count / 10_000
    let rendered =
      tenThousands.rounded() == tenThousands
      ? String(Int(tenThousands))
      : String(tenThousands)
    return rendered + "万字"
  }

  private func resolve(_ raw: String, relativeTo base: String) -> String {
    if let absolute = URL(string: raw), absolute.scheme != nil {
      return absolute.absoluteString.removingPercentEncoding
        ?? absolute.absoluteString
    }
    if
      let baseURL = URL(string: base),
      let resolved = URL(string: raw, relativeTo: baseURL)?.absoluteURL
    {
      return resolved.absoluteString.removingPercentEncoding
        ?? resolved.absoluteString
    }
    guard let slash = base.lastIndex(of: "/") else { return raw }
    return String(base[...slash]) + raw
  }

  private func resolveEndpoint(
    _ raw: String,
    relativeTo base: String
  ) -> SourceEndpoint? {
    guard
      let baseURL = URL(
        string: SourceRequestCompiler.splitURLAndOption(base).url
      ),
      let endpoint = try? SourceEndpoint(
        resolving: raw,
        relativeTo: baseURL
      )
    else {
      return nil
    }
    return endpoint
  }

  private func usesStructuredRules(
    response: SourceSearchResponse,
    rules: SearchRules
  ) -> Bool {
    let list = rules.list.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    if list.lowercased().hasPrefix("@json:") || list.hasPrefix("$") {
      return true
    }
    return (try? JSONValueCodec.decode(Data(response.body.utf8))) != nil
  }

  private func parseStructured(
    response: SourceSearchResponse,
    rules: SearchRules,
    reverse: Bool
  ) async throws -> [SourceSearchBook] {
    let elements = try await SourceVariableRuleEvaluator(
      content: response.body,
      resolver: sharedResolver
    ).getElements(rules.list)
    var seen: Set<String> = []
    var books: [SourceSearchBook] = []
    for element in elements {
      let data = try JSONValueCodec.encode(element)
      let content = String(decoding: data, as: UTF8.self)
      let store = SourceVariableStore(
        policy: .androidRuleData,
        values: await variableStore.snapshot()
      )
      let evaluator = SourceVariableRuleEvaluator(
        content: content,
        resolver: SourceVariableResolver(
          role: .rule,
          scopes: SourceVariableScopes(
            book: store,
            ruleData: store
          )
        )
      )
      let name = try await structuredValue(
        rules.name,
        evaluator: evaluator
      )
      guard !name.isEmpty else { continue }
      let rawBookURL = try await structuredValue(
        rules.bookURL,
        evaluator: evaluator
      )
      guard
        let bookEndpoint = resolveEndpoint(
          rawBookURL.isEmpty ? response.url : rawBookURL,
          relativeTo: response.url
        )
      else {
        continue
      }
      let bookURL = bookEndpoint.logicalURL.absoluteString
      guard seen.insert(bookURL).inserted else { continue }
      let rawCoverURL = try await structuredValue(
        rules.coverURL,
        evaluator: evaluator
      )
      books.append(
        SourceSearchBook(
          name: name,
          author: normalizeAuthor(
            try await structuredValue(
              rules.author,
              evaluator: evaluator
            )
          ),
          kind: try await structuredValue(
            rules.kind,
            evaluator: evaluator
          ),
          wordCount: normalizeWordCount(
            try await structuredValue(
              rules.wordCount,
              evaluator: evaluator
            )
          ),
          intro: try await structuredValue(
            rules.intro,
            evaluator: evaluator
          ),
          lastChapter: try await structuredValue(
            rules.lastChapter,
            evaluator: evaluator
          ),
          bookURL: bookURL,
          bookRequestExpression: bookEndpoint.requestExpression,
          coverURL: rawCoverURL.isEmpty
            ? nil
            : resolve(rawCoverURL, relativeTo: response.url),
          origin: definition.sourceURL,
          originName: definition.sourceName,
          originOrder: definition.originOrder,
          infoHTML: bookURL == response.url ? response.body : nil,
          variables: await store.snapshot()
        )
      )
    }
    return reverse ? Array(books.reversed()) : books
  }

  private func structuredValue(
    _ rule: HTMLCSSRule,
    evaluator: SourceVariableRuleEvaluator
  ) async throws -> String {
    let raw = rule.selector.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    guard raw != "__legado_missing__" else { return "" }
    return try await evaluator.getString(raw).trimmingCharacters(
      in: .whitespacesAndNewlines
    )
  }
}
