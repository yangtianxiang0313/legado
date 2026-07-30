import Foundation
import LegadoCore

struct SourceBookListParser {
  let definition: SourceSearchDefinition

  func parse(
    response: SourceSearchResponse,
    rules: SearchRules,
    reverse: Bool,
    allowsDetailPattern: Bool
  ) throws -> [SourceSearchBook] {
    if usesStructuredRules(response: response, rules: rules) {
      return try parseStructured(
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
        let book = try book(
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

    let nodes = try document.select(
      HTMLCSSRule(normalizedList(rules.list)).cssSelector
    )
    if nodes.isEmpty, definition.bookURLPattern?.isEmpty != false {
      if let detail = try book(
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
        let candidate = try book(
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
  ) throws -> SourceSearchBook? {
    let name = try value(rules.name, in: node, document: document) ?? ""
    guard !name.isEmpty else { return nil }
    let rawBookURL = try rules.bookURL.flatMap {
      try value($0, in: node, document: document)
    }
    let bookURL = rawBookURL.map {
      resolve($0, relativeTo: response.url)
    } ?? fallbackBookURL
    let coverURL = try value(
      rules.coverURL,
      in: node,
      document: document
    ).map {
      resolve($0, relativeTo: response.url)
    }
    return SourceSearchBook(
      name: name,
      author: normalizeAuthor(
        try value(rules.author, in: node, document: document) ?? ""
      ),
      kind: try value(rules.kind, in: node, document: document) ?? "",
      wordCount: normalizeWordCount(
        try value(rules.wordCount, in: node, document: document) ?? ""
      ),
      intro: try value(rules.intro, in: node, document: document) ?? "",
      lastChapter:
        try value(rules.lastChapter, in: node, document: document) ?? "",
      bookURL: bookURL,
      coverURL: coverURL,
      origin: definition.sourceURL,
      originName: definition.sourceName,
      originOrder: definition.originOrder,
      infoHTML:
        preservesHTML || bookURL == response.url
        ? response.body
        : nil
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
  ) throws -> [SourceSearchBook] {
    let elements = try SourceRuleConsumerEvaluator(
      content: response.body
    ).getElements(rules.list)
    var seen: Set<String> = []
    var books: [SourceSearchBook] = []
    for element in elements {
      let data = try JSONValueCodec.encode(element)
      let content = String(decoding: data, as: UTF8.self)
      let evaluator = SourceRuleConsumerEvaluator(content: content)
      let name = try structuredValue(rules.name, evaluator: evaluator)
      guard !name.isEmpty else { continue }
      let rawBookURL = try structuredValue(
        rules.bookURL,
        evaluator: evaluator
      )
      let bookURL = rawBookURL.isEmpty
        ? response.url
        : resolve(rawBookURL, relativeTo: response.url)
      guard seen.insert(bookURL).inserted else { continue }
      let rawCoverURL = try structuredValue(
        rules.coverURL,
        evaluator: evaluator
      )
      books.append(
        SourceSearchBook(
          name: name,
          author: normalizeAuthor(
            try structuredValue(rules.author, evaluator: evaluator)
          ),
          kind: try structuredValue(rules.kind, evaluator: evaluator),
          wordCount: normalizeWordCount(
            try structuredValue(
              rules.wordCount,
              evaluator: evaluator
            )
          ),
          intro: try structuredValue(rules.intro, evaluator: evaluator),
          lastChapter: try structuredValue(
            rules.lastChapter,
            evaluator: evaluator
          ),
          bookURL: bookURL,
          coverURL: rawCoverURL.isEmpty
            ? nil
            : resolve(rawCoverURL, relativeTo: response.url),
          origin: definition.sourceURL,
          originName: definition.sourceName,
          originOrder: definition.originOrder,
          infoHTML: bookURL == response.url ? response.body : nil
        )
      )
    }
    return reverse ? Array(books.reversed()) : books
  }

  private func structuredValue(
    _ rule: HTMLCSSRule,
    evaluator: SourceRuleConsumerEvaluator
  ) throws -> String {
    let raw = rule.selector.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    guard raw != "__legado_missing__" else { return "" }
    return try evaluator.getString(raw).trimmingCharacters(
      in: .whitespacesAndNewlines
    )
  }
}
