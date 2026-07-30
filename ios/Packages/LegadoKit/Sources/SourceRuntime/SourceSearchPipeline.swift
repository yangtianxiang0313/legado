import Foundation

public struct SourceSearchDefinition: Sendable, Equatable {
  public let sourceURL: String
  public let sourceName: String
  public let originOrder: Int
  public let bookURLPattern: String?
  public let runtime: HTMLCSSSourceDefinition

  public init(
    sourceURL: String,
    sourceName: String,
    originOrder: Int,
    bookURLPattern: String? = nil,
    runtime: HTMLCSSSourceDefinition
  ) {
    self.sourceURL = sourceURL
    self.sourceName = sourceName
    self.originOrder = originOrder
    self.bookURLPattern = bookURLPattern
    self.runtime = runtime
  }
}

public struct SourceSearchInput: Sendable, Equatable {
  public let keyword: String
  public let page: Int

  public init(keyword: String, page: Int) {
    self.keyword = keyword
    self.page = page
  }
}

public struct SourceSearchResponse: Sendable, Equatable {
  public let url: String
  public let body: String

  public init(url: String, body: String) {
    self.url = url
    self.body = body
  }
}

public protocol SourceSearchResponseChecking: Sendable {
  func check(
    _ response: SourceSearchResponse,
    source: SourceSearchDefinition,
    input: SourceSearchInput
  ) async throws -> SourceSearchResponse
}

public struct IdentitySourceSearchResponseChecker:
  SourceSearchResponseChecking
{
  public init() {}

  public func check(
    _ response: SourceSearchResponse,
    source: SourceSearchDefinition,
    input: SourceSearchInput
  ) async throws -> SourceSearchResponse {
    response
  }
}

public struct SourceSearchBook: Sendable, Equatable {
  public let name: String
  public let author: String
  public let kind: String
  public let wordCount: String
  public let intro: String
  public let lastChapter: String
  public let bookURL: String
  public let coverURL: String?
  public let origin: String
  public let originName: String
  public let originOrder: Int
  public let infoHTML: String?

  public init(
    name: String,
    author: String,
    kind: String,
    wordCount: String,
    intro: String,
    lastChapter: String,
    bookURL: String,
    coverURL: String?,
    origin: String,
    originName: String,
    originOrder: Int,
    infoHTML: String?
  ) {
    self.name = name
    self.author = author
    self.kind = kind
    self.wordCount = wordCount
    self.intro = intro
    self.lastChapter = lastChapter
    self.bookURL = bookURL
    self.coverURL = coverURL
    self.origin = origin
    self.originName = originName
    self.originOrder = originOrder
    self.infoHTML = infoHTML
  }
}

public struct SourceSearchExecution: Sendable, Equatable {
  public let requestPlan: SourceRequestPlan
  public let response: SourceSearchResponse
  public let books: [SourceSearchBook]

  public init(
    requestPlan: SourceRequestPlan,
    response: SourceSearchResponse,
    books: [SourceSearchBook]
  ) {
    self.requestPlan = requestPlan
    self.response = response
    self.books = books
  }
}

public enum SourceSearchPipelineError: Error, Sendable, Equatable {
  case invalidResponseEncoding
}

public struct SourceSearchPipeline: Sendable {
  private let definition: SourceSearchDefinition
  private let transport: any HTTPTransport
  private let responseChecker: any SourceSearchResponseChecking

  public init(
    definition: SourceSearchDefinition,
    transport: any HTTPTransport,
    responseChecker: any SourceSearchResponseChecking =
      IdentitySourceSearchResponseChecker()
  ) {
    self.definition = definition
    self.transport = transport
    self.responseChecker = responseChecker
  }

  public func search(_ input: SourceSearchInput) async throws
    -> SourceSearchExecution
  {
    guard
      !definition.runtime.searchURLTemplate
        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw SourceRuntimeIssue(
        stage: .fieldEvaluation,
        code: .ruleFailed
      )
    }

    let compilation = try SourceURLTemplateCompiler.compile(
      SourceURLTemplateInput(
        template: definition.runtime.searchURLTemplate,
        key: input.keyword,
        page: input.page,
        baseURL: definition.sourceURL
      )
    )
    let networkResponse = try await transport.execute(
      compilation.plan.request
    )
    guard
      let body = String(
        data: networkResponse.body.bytes,
        encoding: .utf8
      )
    else {
      throw SourceSearchPipelineError.invalidResponseEncoding
    }
    let checked = try await responseChecker.check(
      SourceSearchResponse(
        url: networkResponse.effectiveURL.absoluteString,
        body: body
      ),
      source: definition,
      input: input
    )
    let books = try parse(response: checked)
    return SourceSearchExecution(
      requestPlan: compilation.plan,
      response: checked,
      books: books
    )
  }

  private func parse(
    response: SourceSearchResponse
  ) throws -> [SourceSearchBook] {
    let document: HTMLDocument
    do {
      document = try HTMLDocument(html: response.body)
    } catch {
      throw SourceRuntimeIssue(stage: .parsing, code: .malformedHTML)
    }

    if try matchesDetailPattern(response.url) {
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

    let nodes = try document.select(definition.runtime.search.list)
    var seen: Set<String> = []
    var books: [SourceSearchBook] = []
    for node in nodes {
      guard
        let candidate = try book(
          node: node,
          document: document,
          response: response,
          rules: searchRules(),
          fallbackBookURL: response.url,
          preservesHTML: false
        ),
        seen.insert(candidate.bookURL).inserted
      else {
        continue
      }
      books.append(candidate)
    }
    return books
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

  private func searchRules() -> Rules {
    let rules = definition.runtime.search
    return Rules(
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
      let match = try document.select(rule.selector, within: node).first
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
}
