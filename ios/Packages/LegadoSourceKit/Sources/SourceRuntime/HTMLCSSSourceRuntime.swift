import Foundation
import LegadoCore
import RuleRuntime

public struct HTMLCSSRule: Sendable, Equatable {
  public enum Value: String, Sendable {
    case text
    case href
    case src
    case html
  }

  public let selector: String
  public let value: Value

  public static func optional(
    _ selector: String?,
    value: Value = .text
  ) -> HTMLCSSRule {
    let normalized = selector?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return HTMLCSSRule(
      normalized.isEmpty ? "__legado_missing__" : normalized,
      value: value
    )
  }

  public init(_ selector: String, value: Value = .text) {
    self.selector = selector
    self.value = value
  }

  var cssSelector: String {
    var value = selector.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    if value.lowercased().hasPrefix("@css:") {
      value.removeFirst(5)
    }
    for suffix in ["@text", "@html", "@all", "@href", "@src"] {
      if value.lowercased().hasSuffix(suffix) {
        value.removeLast(suffix.count)
        break
      }
    }
    return value.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

public struct SearchRules: Sendable, Equatable {
  public let list: String
  public let name: HTMLCSSRule
  public let author: HTMLCSSRule
  public let intro: HTMLCSSRule
  public let kind: HTMLCSSRule
  public let wordCount: HTMLCSSRule
  public let lastChapter: HTMLCSSRule
  public let bookURL: HTMLCSSRule
  public let coverURL: HTMLCSSRule

  public init(
    list: String,
    name: HTMLCSSRule,
    author: HTMLCSSRule,
    intro: HTMLCSSRule,
    kind: HTMLCSSRule,
    wordCount: HTMLCSSRule = .optional(nil),
    lastChapter: HTMLCSSRule,
    bookURL: HTMLCSSRule,
    coverURL: HTMLCSSRule
  ) {
    self.list = list
    self.name = name
    self.author = author
    self.intro = intro
    self.kind = kind
    self.wordCount = wordCount
    self.lastChapter = lastChapter
    self.bookURL = bookURL
    self.coverURL = coverURL
  }
}

public struct BookInfoRules: Sendable, Equatable {
  public let name: HTMLCSSRule
  public let author: HTMLCSSRule
  public let intro: HTMLCSSRule
  public let kind: HTMLCSSRule
  public let wordCount: HTMLCSSRule
  public let lastChapter: HTMLCSSRule
  public let coverURL: HTMLCSSRule
  public let tocURL: HTMLCSSRule
  public let allowsRename: Bool

  public init(
    name: HTMLCSSRule,
    author: HTMLCSSRule,
    intro: HTMLCSSRule,
    kind: HTMLCSSRule,
    wordCount: HTMLCSSRule = .optional(nil),
    lastChapter: HTMLCSSRule,
    coverURL: HTMLCSSRule,
    tocURL: HTMLCSSRule,
    allowsRename: Bool = false
  ) {
    self.name = name
    self.author = author
    self.intro = intro
    self.kind = kind
    self.wordCount = wordCount
    self.lastChapter = lastChapter
    self.coverURL = coverURL
    self.tocURL = tocURL
    self.allowsRename = allowsRename
  }
}

public struct TOCRules: Sendable, Equatable {
  public let list: String
  public let name: HTMLCSSRule
  public let url: HTMLCSSRule
  public let isVIP: HTMLCSSRule
  public let isPay: HTMLCSSRule
  public let isVolume: HTMLCSSRule
  public let nextTocURL: HTMLCSSRule?

  public init(
    list: String,
    name: HTMLCSSRule,
    url: HTMLCSSRule,
    isVIP: HTMLCSSRule = .optional(nil),
    isPay: HTMLCSSRule = .optional(nil),
    isVolume: HTMLCSSRule = .optional(nil),
    nextTocURL: HTMLCSSRule? = nil
  ) {
    self.list = list
    self.name = name
    self.url = url
    self.isVIP = isVIP
    self.isPay = isPay
    self.isVolume = isVolume
    self.nextTocURL = nextTocURL
  }
}

public struct ContentRules: Sendable, Equatable {
  public let title: HTMLCSSRule
  public let content: HTMLCSSRule
  public let nextContentURL: HTMLCSSRule?
  public let webJS: String?
  public let sourceRegex: String?
  public let replaceRegex: String?

  public init(
    title: HTMLCSSRule = .optional(nil),
    content: HTMLCSSRule,
    nextContentURL: HTMLCSSRule? = nil
  ) {
    self.title = title
    self.content = content
    self.nextContentURL = nextContentURL
    self.webJS = nil
    self.sourceRegex = nil
    self.replaceRegex = nil
  }

  public init(
    title: HTMLCSSRule = .optional(nil),
    content: HTMLCSSRule,
    nextContentURL: HTMLCSSRule?,
    webJS: String?,
    sourceRegex: String?,
    replaceRegex: String? = nil
  ) {
    self.title = title
    self.content = content
    self.nextContentURL = nextContentURL
    self.webJS = webJS
    self.sourceRegex = sourceRegex
    self.replaceRegex = replaceRegex
  }
}

public struct HTMLCSSSourceDefinition: Sendable, Equatable {
  public let searchURLTemplate: String
  public let search: SearchRules
  public let explore: SearchRules?
  public let bookInfo: BookInfoRules
  public let toc: TOCRules
  public let content: ContentRules

  public init(
    searchURLTemplate: String,
    search: SearchRules,
    explore: SearchRules? = nil,
    bookInfo: BookInfoRules,
    toc: TOCRules,
    content: ContentRules
  ) {
    self.searchURLTemplate = searchURLTemplate
    self.search = search
    self.explore = explore
    self.bookInfo = bookInfo
    self.toc = toc
    self.content = content
  }
}

public struct SourceBook: Sendable, Equatable {
  public let name: String
  public let author: String?
  public let intro: String?
  public let kind: String?
  public let wordCount: String?
  public let lastChapter: String?
  public let bookEndpoint: SourceEndpoint
  public let coverURL: URL?
  public let tocEndpoint: SourceEndpoint?
  public let variables: [String: String]

  public var bookURL: URL {
    bookEndpoint.logicalURL
  }

  public var tocURL: URL? {
    tocEndpoint?.logicalURL
  }

  public init(
    name: String,
    author: String?,
    intro: String?,
    kind: String?,
    wordCount: String? = nil,
    lastChapter: String?,
    bookURL: URL,
    coverURL: URL?,
    tocURL: URL?,
    variables: [String: String] = [:]
  ) {
    self.init(
      name: name,
      author: author,
      intro: intro,
      kind: kind,
      wordCount: wordCount,
      lastChapter: lastChapter,
      bookEndpoint: .plain(bookURL),
      coverURL: coverURL,
      tocEndpoint: tocURL.map(SourceEndpoint.plain),
      variables: variables
    )
  }

  public init(
    name: String,
    author: String?,
    intro: String?,
    kind: String?,
    wordCount: String? = nil,
    lastChapter: String?,
    bookEndpoint: SourceEndpoint,
    coverURL: URL?,
    tocEndpoint: SourceEndpoint?,
    variables: [String: String] = [:]
  ) {
    self.name = name
    self.author = author
    self.intro = intro
    self.kind = kind
    self.wordCount = wordCount
    self.lastChapter = lastChapter
    self.bookEndpoint = bookEndpoint
    self.coverURL = coverURL
    self.tocEndpoint = tocEndpoint
    self.variables = variables
  }

  public func replacingVariables(
    _ variables: [String: String]
  ) -> SourceBook {
    SourceBook(
      name: name,
      author: author,
      intro: intro,
      kind: kind,
      wordCount: wordCount,
      lastChapter: lastChapter,
      bookEndpoint: bookEndpoint,
      coverURL: coverURL,
      tocEndpoint: tocEndpoint,
      variables: variables
    )
  }
}

public struct SourceChapter: Sendable, Equatable {
  public let index: Int
  public let title: String
  public let endpoint: SourceEndpoint
  public let isPay: Bool
  public let isVIP: Bool
  public let isVolume: Bool
  public let variables: [String: String]

  public var url: URL {
    endpoint.logicalURL
  }

  public init(
    index: Int,
    title: String,
    url: URL,
    isPay: Bool,
    isVIP: Bool,
    isVolume: Bool,
    variables: [String: String] = [:]
  ) {
    self.init(
      index: index,
      title: title,
      endpoint: .plain(url),
      isPay: isPay,
      isVIP: isVIP,
      isVolume: isVolume,
      variables: variables
    )
  }

  public init(
    index: Int,
    title: String,
    endpoint: SourceEndpoint,
    isPay: Bool,
    isVIP: Bool,
    isVolume: Bool,
    variables: [String: String] = [:]
  ) {
    self.index = index
    self.title = title
    self.endpoint = endpoint
    self.isPay = isPay
    self.isVIP = isVIP
    self.isVolume = isVolume
    self.variables = variables
  }
}

public struct SourceContent: Sendable, Equatable {
  public let chapterURL: URL
  public let title: String?
  public let content: String
  public let variables: [String: String]

  public init(
    chapterURL: URL,
    title: String? = nil,
    content: String,
    variables: [String: String] = [:]
  ) {
    self.chapterURL = chapterURL
    self.title = title
    self.content = content
    self.variables = variables
  }
}

public struct SourceTOCPage: Sendable, Equatable {
  public let chapters: [SourceChapter]
  public let nextEndpoints: [SourceEndpoint]
  public let bookVariables: [String: String]

  public init(
    chapters: [SourceChapter],
    nextEndpoints: [SourceEndpoint],
    bookVariables: [String: String] = [:]
  ) {
    self.chapters = chapters
    self.nextEndpoints = nextEndpoints
    self.bookVariables = bookVariables
  }
}

public struct SourceContentPage: Sendable, Equatable {
  public let content: SourceContent
  public let nextEndpoints: [SourceEndpoint]
}

public struct SourceRuntimeIssue: Error, Sendable, Equatable {
  public enum Stage: String, Sendable {
    case urlTemplate = "url_template"
    case parsing
    case fieldEvaluation = "field_evaluation"
  }

  public enum Code: String, Sendable {
    case invalidURL = "invalid_url"
    case malformedHTML = "malformed_html"
    case ruleFailed = "rule_failed"
  }

  public let stage: Stage
  public let code: Code
}

public struct HTMLCSSSourceRuntime: Sendable {
  public let definition: HTMLCSSSourceDefinition
  public let scriptRuntime: (any SourceScriptRuntime)?
  public let scriptSessionID: SourceScriptSessionID?
  public let scriptLibrary: SourceScriptLibrary?
  public let sourceUserVariable: String
  public let htmlSelectorBackend: (any HTMLSelectorBackend)?

  public init(
    definition: HTMLCSSSourceDefinition,
    scriptRuntime: (any SourceScriptRuntime)? = nil,
    scriptSessionID: SourceScriptSessionID? = nil,
    scriptLibrary: SourceScriptLibrary? = nil,
    sourceUserVariable: String = "",
    htmlSelectorBackend: (any HTMLSelectorBackend)? = nil
  ) {
    self.definition = definition
    self.scriptRuntime = scriptRuntime
    self.scriptSessionID = scriptSessionID
    self.scriptLibrary = scriptLibrary
    self.sourceUserVariable = sourceUserVariable
    self.htmlSelectorBackend = htmlSelectorBackend
  }

  public func searchRequest(keyword: String) throws -> HTTPRequest {
    try searchRequestPlan(keyword: keyword).request
  }

  public func searchRequestPlan(keyword: String) throws -> SourceRequestPlan {
    try SourceRequestCompiler.compile(
      template: definition.searchURLTemplate,
      keyword: keyword
    )
  }

  public func request(for url: URL) throws -> HTTPRequest {
    try request(for: url.absoluteString)
  }

  public func search(html: String, responseURL: URL) throws -> [SourceBook] {
    let document = try parse(html)
    return try document.select(
      HTMLCSSRule(definition.search.list).cssSelector
    ).compactMap { node in
      guard
        let name = try value(definition.search.name, in: node, document: document),
        let book = try resolvedEndpoint(
          definition.search.bookURL,
          in: node,
          document: document,
          base: responseURL
        )
      else { return nil }
      return SourceBook(
        name: name,
        author: try value(definition.search.author, in: node, document: document),
        intro: try value(definition.search.intro, in: node, document: document),
        kind: try value(definition.search.kind, in: node, document: document),
        lastChapter: try value(definition.search.lastChapter, in: node, document: document),
        bookEndpoint: book,
        coverURL: try resolved(definition.search.coverURL, in: node, document: document, base: responseURL),
        tocEndpoint: nil
      )
    }
  }

  public func bookInfo(html: String, bookURL: URL) throws -> SourceBook {
    try bookInfo(
      html: html,
      baseURL: bookURL,
      redirectURL: bookURL,
      existing: SourceBook(
        name: "",
        author: nil,
        intro: nil,
        kind: nil,
        lastChapter: nil,
        bookURL: bookURL,
        coverURL: nil,
        tocURL: nil
      ),
      canRename: true
    )
  }

  public func bookInfo(
    html: String,
    baseURL: URL,
    redirectURL: URL,
    existing: SourceBook,
    canRename: Bool
  ) throws -> SourceBook {
    if usesStructuredRules(
      content: html,
      rules: [
        definition.bookInfo.name,
        definition.bookInfo.author,
        definition.bookInfo.tocURL,
      ]
    ) {
      return try structuredBookInfo(
        content: html,
        baseURL: baseURL,
        redirectURL: redirectURL,
        existing: existing,
        canRename: canRename
      )
    }
    let document = try parse(html)
    let parsedName = normalizeName(
      try value(
        definition.bookInfo.name,
        in: document.root,
        document: document
      )
    )
    let parsedAuthor = normalizeAuthor(
      try value(
        definition.bookInfo.author,
        in: document.root,
        document: document
      )
    )
    let mayRename = canRename && definition.bookInfo.allowsRename
    let name = replacement(
      existing: existing.name,
      parsed: parsedName,
      mayReplaceExisting: mayRename
    )
    guard !name.isEmpty else {
      throw SourceRuntimeIssue(
        stage: .fieldEvaluation,
        code: .ruleFailed
      )
    }
    let author = replacement(
      existing: existing.author,
      parsed: parsedAuthor,
      mayReplaceExisting: mayRename
    )
    let toc =
      try resolvedEndpoint(
        definition.bookInfo.tocURL,
        in: document.root,
        document: document,
        base: baseURL
      ) ?? existing.bookEndpoint
    return SourceBook(
      name: name,
      author: author,
      intro: optionalValue(
        definition.bookInfo.intro,
        in: document,
        fallback: existing.intro
      ),
      kind: optionalValue(
        definition.bookInfo.kind,
        in: document,
        fallback: existing.kind
      ),
      wordCount: normalizeWordCount(
        optionalValue(
          definition.bookInfo.wordCount,
          in: document,
          fallback: existing.wordCount
        )
      ),
      lastChapter: optionalValue(
        definition.bookInfo.lastChapter,
        in: document,
        fallback: existing.lastChapter
      ),
      bookEndpoint: existing.bookEndpoint,
      coverURL: optionalURL(
        definition.bookInfo.coverURL,
        in: document,
        base: redirectURL,
        fallback: existing.coverURL
      ),
      tocEndpoint: toc,
      variables: existing.variables
    )
  }

  public func bookInfo(
    html: String,
    baseURL: URL,
    redirectURL: URL,
    existing: SourceBook,
    canRename: Bool,
    variableStore: SourceVariableStore
  ) async throws -> SourceBook {
    let resolver = SourceVariableResolver(
      role: .rule,
      scopes: SourceVariableScopes(
        book: variableStore,
        ruleData: variableStore,
        sourceUserVariable: sourceUserVariable,
        bookName: existing.name
      )
    )
    let rules = definition.bookInfo
    let strings: (HTMLCSSRule) async throws -> String?
    if usesStructuredRules(
      content: html,
      rules: [rules.name, rules.author, rules.tocURL]
    ) {
      let evaluator = SourceVariableRuleEvaluator(
        content: html,
        resolver: resolver,
        scriptRuntime: scriptRuntime,
        scriptSessionID: scriptSessionID,
        scriptLibrary: scriptLibrary,
        baseURL: redirectURL.absoluteString,
        htmlSelectorBackend: htmlSelectorBackend
      )
      strings = { rule in
        let value = try await evaluator.getString(rule.selector)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
      }
    } else {
      let document = try parse(html)
      let evaluator = SourceVariableHTMLRuleEvaluator(
        document: document,
        node: document.root,
        resolver: resolver,
        scriptRuntime: scriptRuntime,
        scriptSessionID: scriptSessionID,
        scriptLibrary: scriptLibrary,
        baseURL: redirectURL.absoluteString
      )
      strings = { rule in
        try await evaluator.string(rule)
      }
    }
    let parsedName = normalizeName(
      try await strings(rules.name)
    )
    let parsedAuthor = normalizeAuthor(
      try await strings(rules.author)
    )
    let mayRename = canRename && rules.allowsRename
    let name = replacement(
      existing: existing.name,
      parsed: parsedName,
      mayReplaceExisting: mayRename
    )
    guard !name.isEmpty else {
      throw SourceRuntimeIssue(
        stage: .fieldEvaluation,
        code: .ruleFailed
      )
    }
    let rawTOC = try await strings(rules.tocURL)
    let rawCover = try await strings(rules.coverURL)
    return SourceBook(
      name: name,
      author: replacement(
        existing: existing.author,
        parsed: parsedAuthor,
        mayReplaceExisting: mayRename
      ),
      intro: try await strings(rules.intro) ?? existing.intro,
      kind: try await strings(rules.kind) ?? existing.kind,
      wordCount: normalizeWordCount(
        try await strings(rules.wordCount)
          ?? existing.wordCount
      ),
      lastChapter:
        try await strings(rules.lastChapter)
        ?? existing.lastChapter,
      bookEndpoint: existing.bookEndpoint,
      coverURL: rawCover.flatMap {
        URL(string: $0, relativeTo: redirectURL)?.absoluteURL
      } ?? existing.coverURL,
      tocEndpoint: try rawTOC.map {
        try SourceEndpoint(resolving: $0, relativeTo: baseURL)
      } ?? existing.bookEndpoint,
      variables: await variableStore.snapshot()
    )
  }

  public func chapters(html: String, tocURL: URL) throws -> [SourceChapter] {
    try chapters(html: html, tocEndpoint: .plain(tocURL))
  }

  public func chapters(
    html: String,
    tocEndpoint: SourceEndpoint
  ) throws -> [SourceChapter] {
    try chapterPage(
      html: html,
      tocEndpoint: tocEndpoint
    ).chapters
  }

  public func chapterPage(
    html: String,
    tocEndpoint: SourceEndpoint
  ) throws -> SourceTOCPage {
    SourceTOCPage(
      chapters: try parsedChapters(
        html: html,
        tocEndpoint: tocEndpoint
      ),
      nextEndpoints: try paginationEndpoints(
        html: html,
        rule: definition.toc.nextTocURL,
        currentEndpoint: tocEndpoint
      )
    )
  }

  public func chapterPage(
    html: String,
    tocEndpoint: SourceEndpoint,
    variableStore: SourceVariableStore
  ) async throws -> SourceTOCPage {
    let bookResolver = SourceVariableResolver(
      role: .rule,
      scopes: SourceVariableScopes(
        book: variableStore,
        ruleData: variableStore,
        sourceUserVariable: sourceUserVariable
      )
    )
    let rules = definition.toc
    let chapters: [SourceChapter]
    let nextValues: [String]
    if usesStructuredRules(
      content: html,
      rules: [
        HTMLCSSRule(rules.list),
        rules.name,
        rules.url,
      ]
    ) {
      let listEvaluator = SourceVariableRuleEvaluator(
        content: html,
        resolver: bookResolver,
        scriptRuntime: scriptRuntime,
        scriptSessionID: scriptSessionID,
        scriptLibrary: scriptLibrary,
        baseURL: tocEndpoint.logicalURL.absoluteString,
        htmlSelectorBackend: htmlSelectorBackend
      )
      let elements = try await listEvaluator.getElements(rules.list)
      chapters = try await elements.enumerated().asyncMap {
        index, element in
        let data = try JSONValueCodec.encode(element)
        let localContent = String(decoding: data, as: UTF8.self)
        let chapterStore = SourceVariableStore()
        let evaluator = SourceVariableRuleEvaluator(
          content: localContent,
          resolver: SourceVariableResolver(
            role: .rule,
            scopes: SourceVariableScopes(
              chapter: chapterStore,
              book: variableStore,
              ruleData: variableStore,
              sourceUserVariable: sourceUserVariable
            )
          ),
          scriptRuntime: scriptRuntime,
          scriptSessionID: scriptSessionID,
          scriptLibrary: scriptLibrary,
          baseURL: tocEndpoint.logicalURL.absoluteString,
          htmlSelectorBackend: htmlSelectorBackend
        )
        let title = try await evaluator.getString(
          rules.name.selector
        )
        let rawURL = try await evaluator.getString(
          rules.url.selector
        )
        guard !title.isEmpty else {
          throw SourceRuntimeIssue(
            stage: .fieldEvaluation,
            code: .ruleFailed
          )
        }
        let isVolume = androidIsTrue(
          try await evaluator.getString(rules.isVolume.selector)
        )
        return SourceChapter(
          index: index,
          title: title,
          endpoint: try chapterEndpoint(
            rawURL: rawURL,
            title: title,
            index: index,
            isVolume: isVolume,
            tocEndpoint: tocEndpoint
          ),
          isPay: androidIsTrue(
            try await evaluator.getString(rules.isPay.selector)
          ),
          isVIP: androidIsTrue(
            try await evaluator.getString(rules.isVIP.selector)
          ),
          isVolume: isVolume,
          variables: await chapterStore.snapshot()
        )
      }
      if let nextRule = rules.nextTocURL {
        nextValues =
          try await listEvaluator.getStringList(
            nextRule.selector
          ) ?? []
      } else {
        nextValues = []
      }
    } else {
      let document = try parse(html)
      let listEvaluator = SourceVariableHTMLRuleEvaluator(
        document: document,
        node: document.root,
        resolver: bookResolver,
        scriptRuntime: scriptRuntime,
        scriptSessionID: scriptSessionID,
        scriptLibrary: scriptLibrary,
        baseURL: tocEndpoint.logicalURL.absoluteString
      )
      let nodes = try await listEvaluator.elements(rules.list)
      chapters = try await nodes.enumerated().asyncMap {
        index, node in
        let chapterStore = SourceVariableStore()
        let evaluator = SourceVariableHTMLRuleEvaluator(
          document: document,
          node: node,
          resolver: SourceVariableResolver(
            role: .rule,
            scopes: SourceVariableScopes(
              chapter: chapterStore,
              book: variableStore,
              ruleData: variableStore,
              sourceUserVariable: sourceUserVariable
            )
          ),
          scriptRuntime: scriptRuntime,
          scriptSessionID: scriptSessionID,
          scriptLibrary: scriptLibrary,
          baseURL: tocEndpoint.logicalURL.absoluteString
        )
        guard let title = try await evaluator.string(rules.name), !title.isEmpty else {
          throw SourceRuntimeIssue(
            stage: .fieldEvaluation,
            code: .ruleFailed
          )
        }
        let isVolume = androidIsTrue(
          try await evaluator.string(rules.isVolume) ?? ""
        )
        return SourceChapter(
          index: index,
          title: title,
          endpoint: try chapterEndpoint(
            rawURL: try await evaluator.string(rules.url) ?? "",
            title: title,
            index: index,
            isVolume: isVolume,
            tocEndpoint: tocEndpoint
          ),
          isPay: androidIsTrue(
            try await evaluator.string(rules.isPay) ?? ""
          ),
          isVIP: androidIsTrue(
            try await evaluator.string(rules.isVIP) ?? ""
          ),
          isVolume: isVolume,
          variables: await chapterStore.snapshot()
        )
      }
      if let nextRule = rules.nextTocURL {
        nextValues = try await listEvaluator.strings(nextRule)
      } else {
        nextValues = []
      }
    }
    guard !chapters.isEmpty else {
      throw SourceRuntimeIssue(
        stage: .fieldEvaluation,
        code: .ruleFailed
      )
    }
    return SourceTOCPage(
      chapters: chapters,
      nextEndpoints: resolvedPaginationEndpoints(
        nextValues,
        currentEndpoint: tocEndpoint
      ),
      bookVariables: await variableStore.snapshot()
    )
  }

  private func parsedChapters(
    html: String,
    tocEndpoint: SourceEndpoint
  ) throws -> [SourceChapter] {
    let tocURL = tocEndpoint.logicalURL
    if usesStructuredRules(
      content: html,
      rules: [
        HTMLCSSRule(definition.toc.list),
        definition.toc.name,
        definition.toc.url,
      ]
    ) {
      return try structuredChapters(content: html, tocURL: tocURL)
    }
    let document = try parse(html)
    let nodes = try document.select(
      HTMLCSSRule(definition.toc.list).cssSelector
    )
    guard !nodes.isEmpty else {
      throw SourceRuntimeIssue(stage: .fieldEvaluation, code: .ruleFailed)
    }
    return try nodes.enumerated().map { index, node in
      guard
        let title = try value(definition.toc.name, in: node, document: document),
        let rawURL = try value(definition.toc.url, in: node, document: document)
      else { throw SourceRuntimeIssue(stage: .fieldEvaluation, code: .ruleFailed) }
      let isVolume = androidIsTrue(
        try value(definition.toc.isVolume, in: node, document: document) ?? ""
      )
      return SourceChapter(
        index: index,
        title: title,
        endpoint: try chapterEndpoint(
          rawURL: rawURL,
          title: title,
          index: index,
          isVolume: isVolume,
          tocEndpoint: .plain(tocURL)
        ),
        isPay: androidIsTrue(
          try value(definition.toc.isPay, in: node, document: document) ?? ""
        ),
        isVIP: androidIsTrue(
          try value(definition.toc.isVIP, in: node, document: document) ?? ""
        ),
        isVolume: isVolume
      )
    }
  }

  public func content(html: String, chapterURL: URL) throws -> SourceContent {
    try contentPage(
      html: html,
      chapterEndpoint: .plain(chapterURL)
    ).content
  }

  public func contentPage(
    html: String,
    chapterEndpoint: SourceEndpoint
  ) throws -> SourceContentPage {
    SourceContentPage(
      content: try parsedContent(
        html: html,
        chapterURL: chapterEndpoint.logicalURL
      ),
      nextEndpoints: try paginationEndpoints(
        html: html,
        rule: definition.content.nextContentURL,
        currentEndpoint: chapterEndpoint
      )
    )
  }

  public func contentPage(
    html: String,
    chapterEndpoint: SourceEndpoint,
    bookVariables: [String: String],
    chapterVariables: [String: String]
  ) async throws -> SourceContentPage {
    let bookStore = SourceVariableStore(values: bookVariables)
    let chapterStore = SourceVariableStore(values: chapterVariables)
    let resolver = SourceVariableResolver(
      role: .rule,
      scopes: SourceVariableScopes(
        chapter: chapterStore,
        book: bookStore,
        ruleData: bookStore,
        sourceUserVariable: sourceUserVariable
      )
    )
    let rules = definition.content
    let value: String
    let title: String?
    let nextValues: [String]
    if usesStructuredRules(
      content: html,
      rules: [rules.content]
    ) {
      let evaluator = SourceVariableRuleEvaluator(
        content: html,
        resolver: resolver,
        scriptRuntime: scriptRuntime,
        scriptSessionID: scriptSessionID,
        scriptLibrary: scriptLibrary,
        baseURL: chapterEndpoint.logicalURL.absoluteString,
        htmlSelectorBackend: htmlSelectorBackend
      )
      value = try await evaluator.getString(
        rules.content.selector
      )
      let parsedTitle = try await evaluator.getString(rules.title.selector)
      let normalizedTitle = parsedTitle.trimmingCharacters(
        in: .whitespacesAndNewlines
      )
      title = normalizedTitle.isEmpty ? nil : normalizedTitle
      if let nextRule = rules.nextContentURL {
        nextValues =
          try await evaluator.getStringList(
            nextRule.selector
          ) ?? []
      } else {
        nextValues = []
      }
    } else {
      let document = try parse(html)
      let evaluator = SourceVariableHTMLRuleEvaluator(
        document: document,
        node: document.root,
        resolver: resolver,
        scriptRuntime: scriptRuntime,
        scriptSessionID: scriptSessionID,
        scriptLibrary: scriptLibrary,
        baseURL: chapterEndpoint.logicalURL.absoluteString
      )
      let executionRule = try await evaluator.prepare(
        rules.content
      )
      guard
        let node = try document.select(
          HTMLCSSRule(executionRule).cssSelector
        ).first
      else {
        throw SourceRuntimeIssue(
          stage: .fieldEvaluation,
          code: .ruleFailed
        )
      }
      value = formattedContent(
        node: node,
        chapterURL: chapterEndpoint.logicalURL
      )
      let parsedTitle = try await evaluator.string(rules.title)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      title = parsedTitle.isEmpty ? nil : parsedTitle
      if let nextRule = rules.nextContentURL {
        nextValues = try await evaluator.strings(nextRule)
      } else {
        nextValues = []
      }
    }
    guard
      !value.trimmingCharacters(
        in: .whitespacesAndNewlines
      ).isEmpty
    else {
      throw SourceRuntimeIssue(
        stage: .fieldEvaluation,
        code: .ruleFailed
      )
    }
    return SourceContentPage(
      content: SourceContent(
        chapterURL: chapterEndpoint.logicalURL,
        title: title,
        content: value,
        variables: await chapterStore.snapshot()
      ),
      nextEndpoints: resolvedPaginationEndpoints(
        nextValues,
        currentEndpoint: chapterEndpoint
      )
    )
  }

  private func parsedContent(
    html: String,
    chapterURL: URL
  ) throws -> SourceContent {
    if usesStructuredRules(
      content: html,
      rules: [definition.content.content]
    ) {
      let evaluator = SourceRuleConsumerEvaluator(
        content: html,
        htmlSelectorBackend: htmlSelectorBackend
      )
      let value = try evaluator.getString(
        definition.content.content.selector
      )
      guard
        !value.trimmingCharacters(
          in: .whitespacesAndNewlines
        ).isEmpty
      else {
        throw SourceRuntimeIssue(
          stage: .fieldEvaluation,
          code: .ruleFailed
        )
      }
      return SourceContent(chapterURL: chapterURL, content: value)
    }
    let document = try parse(html)
    guard
      let node = try document.select(
        definition.content.content.cssSelector
      ).first
    else {
      throw SourceRuntimeIssue(stage: .fieldEvaluation, code: .ruleFailed)
    }
    let value = formattedContent(node: node, chapterURL: chapterURL)
    guard !value.isEmpty else {
      throw SourceRuntimeIssue(stage: .fieldEvaluation, code: .ruleFailed)
    }
    return SourceContent(chapterURL: chapterURL, content: value)
  }

  private func formattedContent(
    node: HTMLNode,
    chapterURL: URL
  ) -> String {
    guard var value = node.outerHTML else {
      let lines = node.children.compactMap { child -> String? in
        switch child.name {
        case "p":
          let text = child.normalizedText
          return text.isEmpty ? nil : "　　" + text
        case "img":
          guard
            let raw = child.attributes["src"],
            let url = URL(
              string: raw,
              relativeTo: chapterURL
            )?.absoluteURL
          else { return nil }
          return "　　<img src=\"\(url.absoluteString)\">"
        default:
          let text = child.normalizedText
          return text.isEmpty ? nil : "　　" + text
        }
      }
      if lines.isEmpty {
        let text = node.normalizedText
        return text.isEmpty ? "" : "　　" + text
      }
      return lines.joined(separator: "\n")
    }
    value = replacing(
      value,
      pattern: #"<(?:script|style)\b[^>]*>[\s\S]*?</(?:script|style)>"#,
      with: ""
    )
    value = replacing(value, pattern: #"(&nbsp;)+"#, with: " ")
    value = replacing(value, pattern: #"(&ensp;|&emsp;)"#, with: " ")
    value = replacing(
      value,
      pattern: #"(&thinsp;|&zwnj;|&zwj;|\u{2009}|\u{200C}|\u{200D})"#,
      with: ""
    )
    value = replacing(
      value,
      pattern: #"</?(?:div|p|br|hr|h\d|article|dd|dl)[^>]*>"#,
      with: "\n"
    )
    value = replacing(value, pattern: #"<!--[\s\S]*?-->"#, with: "")
    value = replacing(
      value,
      pattern: #"</?(?!img)[a-zA-Z]+(?=[ >])[^<>]*>"#,
      with: ""
    )
    value = absoluteImageSources(in: value, relativeTo: chapterURL)
    value = replacing(value, pattern: #"\s*\n+\s*"#, with: "\n　　")
    value = replacing(value, pattern: #"^[\n\s]+"#, with: "　　")
    return replacing(value, pattern: #"[\n\s]+$"#, with: "")
  }

  private func replacing(
    _ value: String,
    pattern: String,
    with replacement: String
  ) -> String {
    value.replacingOccurrences(
      of: pattern,
      with: replacement,
      options: .regularExpression
    )
  }

  private func absoluteImageSources(
    in html: String,
    relativeTo baseURL: URL
  ) -> String {
    guard
      let expression = try? NSRegularExpression(
        pattern: #"<img[^>]*>"#,
        options: [.caseInsensitive]
      ),
      let dataSource = try? NSRegularExpression(
        pattern: #"\sdata-[^=>]*=\s*\"([^\">]*)\""#,
        options: [.caseInsensitive]
      ),
      let source = try? NSRegularExpression(
        pattern: #"\ssrc\s*=\s*\"([^\">]*)\""#,
        options: [.caseInsensitive]
      )
    else { return html }
    let result = NSMutableString(string: html)
    let matches = expression.matches(
      in: html,
      range: NSRange(html.startIndex..., in: html)
    )
    for match in matches.reversed() {
      guard let tagRange = Range(match.range(at: 0), in: html) else {
        continue
      }
      let tag = String(html[tagRange])
      let tagRangeUTF16 = NSRange(tag.startIndex..., in: tag)
      let sourceMatch = dataSource.firstMatch(
        in: tag,
        range: tagRangeUTF16
      ) ?? source.firstMatch(in: tag, range: tagRangeUTF16)
      guard
        let sourceMatch,
        let sourceRange = Range(sourceMatch.range(at: 1), in: tag),
        let absolute = URL(
          string: String(tag[sourceRange]),
          relativeTo: baseURL
        )?.absoluteURL
      else { continue }
      result.replaceCharacters(
        in: match.range(at: 0),
        with: "<img src=\"\(absolute.absoluteString)\">"
      )
    }
    return result as String
  }

  private func paginationEndpoints(
    html: String,
    rule: HTMLCSSRule?,
    currentEndpoint: SourceEndpoint
  ) throws -> [SourceEndpoint] {
    guard let rule else { return [] }
    let rawValues: [String]
    if usesStructuredRules(content: html, rules: [rule]) {
      rawValues = try SourceRuleConsumerEvaluator(
        content: html,
        htmlSelectorBackend: htmlSelectorBackend
      ).getStringList(rule.selector) ?? []
    } else {
      let document = try parse(html)
      rawValues = try document.select(rule.cssSelector).compactMap {
        node in
        switch rule.value {
        case .text, .html:
          let value = node.normalizedText
          return value.isEmpty ? nil : value
        case .href:
          return node.attributes["href"]
        case .src:
          return node.attributes["src"]
        }
      }
    }
    return resolvedPaginationEndpoints(
      rawValues,
      currentEndpoint: currentEndpoint
    )
  }

  private func resolvedPaginationEndpoints(
    _ rawValues: [String],
    currentEndpoint: SourceEndpoint
  ) -> [SourceEndpoint] {
    var seen: Set<String> = []
    return rawValues.compactMap { raw in
      guard
        let endpoint = try? SourceEndpoint(
          resolving: raw,
          relativeTo: currentEndpoint.logicalURL
        ),
        endpoint.requestExpression != currentEndpoint.requestExpression,
        seen.insert(endpoint.requestExpression).inserted
      else {
        return nil
      }
      return endpoint
    }
  }

  private func parse(_ html: String) throws -> HTMLDocument {
    do {
      return try HTMLDocument(
        html: html,
        selectorBackend: htmlSelectorBackend
      )
    }
    catch { throw SourceRuntimeIssue(stage: .parsing, code: .malformedHTML) }
  }

  private func request(for absoluteURL: String) throws -> HTTPRequest {
    do {
      return HTTPRequest(method: .get, url: try HTTPURL(absoluteURL))
    } catch {
      throw SourceRuntimeIssue(stage: .urlTemplate, code: .invalidURL)
    }
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
    else { return nil }
    let raw: String?
    switch rule.value {
    case .text, .html: raw = match.normalizedText
    case .href: raw = match.attributes["href"]
    case .src: raw = match.attributes["src"]
    }
    guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return raw
  }

  private func resolved(
    _ rule: HTMLCSSRule,
    in node: HTMLNode,
    document: HTMLDocument,
    base: URL
  ) throws -> URL? {
    guard let raw = try value(rule, in: node, document: document) else { return nil }
    return URL(string: raw, relativeTo: base)?.absoluteURL
  }

  private func resolvedEndpoint(
    _ rule: HTMLCSSRule,
    in node: HTMLNode,
    document: HTMLDocument,
    base: URL
  ) throws -> SourceEndpoint? {
    guard
      let raw = try value(rule, in: node, document: document)
    else {
      return nil
    }
    return try SourceEndpoint(resolving: raw, relativeTo: base)
  }

  private func optionalValue(
    _ rule: HTMLCSSRule,
    in document: HTMLDocument,
    fallback: String?
  ) -> String? {
    do {
      return try value(
        rule,
        in: document.root,
        document: document
      ) ?? fallback
    } catch {
      return fallback
    }
  }

  private func optionalURL(
    _ rule: HTMLCSSRule,
    in document: HTMLDocument,
    base: URL,
    fallback: URL?
  ) -> URL? {
    do {
      return try resolved(
        rule,
        in: document.root,
        document: document,
        base: base
      ) ?? fallback
    } catch {
      return fallback
    }
  }

  private func replacement(
    existing: String,
    parsed: String?,
    mayReplaceExisting: Bool
  ) -> String {
    guard
      let parsed,
      !parsed.isEmpty,
      mayReplaceExisting || existing.isEmpty
    else {
      return existing
    }
    return parsed
  }

  private func replacement(
    existing: String?,
    parsed: String?,
    mayReplaceExisting: Bool
  ) -> String? {
    guard
      let parsed,
      !parsed.isEmpty,
      mayReplaceExisting || existing?.isEmpty != false
    else {
      return existing
    }
    return parsed
  }

  private func normalizeName(_ value: String?) -> String? {
    value?
      .replacingOccurrences(of: "书名：", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func normalizeAuthor(_ value: String?) -> String? {
    value?
      .replacingOccurrences(of: "作者：", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func normalizeWordCount(_ value: String?) -> String? {
    guard
      let value,
      let count = Double(
        value.replacingOccurrences(
          of: #"[^0-9.]"#,
          with: "",
          options: .regularExpression
        )
      )
    else {
      return value
    }
    if count >= 10_000 {
      let units = count / 10_000
      let formatted =
        units.rounded() == units
        ? String(Int(units))
        : String(format: "%.1f", units)
      return "\(formatted)万字"
    }
    return "\(Int(count))字"
  }

  private func structuredBookInfo(
    content: String,
    baseURL: URL,
    redirectURL: URL,
    existing: SourceBook,
    canRename: Bool
  ) throws -> SourceBook {
    let evaluator = SourceRuleConsumerEvaluator(
      content: content,
      htmlSelectorBackend: htmlSelectorBackend
    )
    let rules = definition.bookInfo
    let parsedName = normalizeName(
      try structuredValue(rules.name, evaluator: evaluator)
    )
    let parsedAuthor = normalizeAuthor(
      try structuredValue(rules.author, evaluator: evaluator)
    )
    let mayRename = canRename && rules.allowsRename
    let name = replacement(
      existing: existing.name,
      parsed: parsedName,
      mayReplaceExisting: mayRename
    )
    guard !name.isEmpty else {
      throw SourceRuntimeIssue(
        stage: .fieldEvaluation,
        code: .ruleFailed
      )
    }
    let rawTOC = try structuredValue(rules.tocURL, evaluator: evaluator)
    let rawCover = try structuredValue(
      rules.coverURL,
      evaluator: evaluator
    )
    return SourceBook(
      name: name,
      author: replacement(
        existing: existing.author,
        parsed: parsedAuthor,
        mayReplaceExisting: mayRename
      ),
      intro: try structuredOptionalValue(
        rules.intro,
        evaluator: evaluator,
        fallback: existing.intro
      ),
      kind: try structuredOptionalValue(
        rules.kind,
        evaluator: evaluator,
        fallback: existing.kind
      ),
      wordCount: normalizeWordCount(
        try structuredOptionalValue(
          rules.wordCount,
          evaluator: evaluator,
          fallback: existing.wordCount
        )
      ),
      lastChapter: try structuredOptionalValue(
        rules.lastChapter,
        evaluator: evaluator,
        fallback: existing.lastChapter
      ),
      bookEndpoint: existing.bookEndpoint,
      coverURL: rawCover.flatMap {
        URL(string: $0, relativeTo: redirectURL)?.absoluteURL
      } ?? existing.coverURL,
      tocEndpoint: try rawTOC.map {
        try SourceEndpoint(resolving: $0, relativeTo: baseURL)
      } ?? existing.bookEndpoint,
      variables: existing.variables
    )
  }

  private func structuredChapters(
    content: String,
    tocURL: URL
  ) throws -> [SourceChapter] {
    let elements = try SourceRuleConsumerEvaluator(
      content: content,
      htmlSelectorBackend: htmlSelectorBackend
    ).getElements(definition.toc.list)
    guard !elements.isEmpty else {
      throw SourceRuntimeIssue(
        stage: .fieldEvaluation,
        code: .ruleFailed
      )
    }
    return try elements.enumerated().map { index, element in
      let data = try JSONValueCodec.encode(element)
      let localContent = String(decoding: data, as: UTF8.self)
      let evaluator = SourceRuleConsumerEvaluator(
        content: localContent,
        htmlSelectorBackend: htmlSelectorBackend
      )
      guard
        let title = try structuredValue(
          definition.toc.name,
          evaluator: evaluator
        ),
        let rawURL = try structuredOptionalValue(
          definition.toc.url,
          evaluator: evaluator,
          fallback: ""
        )
      else {
        throw SourceRuntimeIssue(
          stage: .fieldEvaluation,
          code: .ruleFailed
        )
      }
      let isVolume = androidIsTrue(
        try structuredOptionalValue(
          definition.toc.isVolume,
          evaluator: evaluator,
          fallback: ""
        ) ?? ""
      )
      return SourceChapter(
        index: index,
        title: title,
        endpoint: try chapterEndpoint(
          rawURL: rawURL,
          title: title,
          index: index,
          isVolume: isVolume,
          tocEndpoint: .plain(tocURL)
        ),
        isPay: androidIsTrue(
          try structuredOptionalValue(
            definition.toc.isPay,
            evaluator: evaluator,
            fallback: ""
          ) ?? ""
        ),
        isVIP: androidIsTrue(
          try structuredOptionalValue(
            definition.toc.isVIP,
            evaluator: evaluator,
            fallback: ""
          ) ?? ""
        ),
        isVolume: isVolume
      )
    }
  }

  private func structuredValue(
    _ rule: HTMLCSSRule,
    evaluator: SourceRuleConsumerEvaluator
  ) throws -> String? {
    let raw = rule.selector.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    guard raw != "__legado_missing__", !raw.isEmpty else {
      return nil
    }
    let value = try evaluator.getString(raw).trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    return value.isEmpty ? nil : value
  }

  private func structuredOptionalValue(
    _ rule: HTMLCSSRule,
    evaluator: SourceRuleConsumerEvaluator,
    fallback: String?
  ) throws -> String? {
    try structuredValue(rule, evaluator: evaluator) ?? fallback
  }

  private func chapterEndpoint(
    rawURL: String,
    title: String,
    index: Int,
    isVolume: Bool,
    tocEndpoint: SourceEndpoint
  ) throws -> SourceEndpoint {
    let trimmedURL = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedURL.isEmpty {
      return try SourceEndpoint(
        resolving: trimmedURL,
        relativeTo: tocEndpoint.logicalURL
      )
    }
    if isVolume {
      return .syntheticVolume(
        title: title,
        index: index,
        fallbackURL: tocEndpoint.logicalURL
      )
    }
    return .plain(tocEndpoint.logicalURL)
  }

  private func androidIsTrue(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.lowercased() != "null" else {
      return false
    }
    return !["false", "no", "not", "0"].contains(trimmed.lowercased())
  }

  private func usesStructuredRules(
    content: String,
    rules: [HTMLCSSRule]
  ) -> Bool {
    if rules.contains(where: {
      let value = $0.selector.trimmingCharacters(
        in: .whitespacesAndNewlines
      )
      return value.lowercased().hasPrefix("@json:")
        || value.hasPrefix("$")
    }) {
      return true
    }
    guard let data = content.data(using: .utf8) else { return false }
    return (try? JSONSerialization.jsonObject(with: data)) != nil
  }
}

private extension Sequence {
  func asyncMap<Result>(
    _ transform: (Element) async throws -> Result
  ) async rethrows -> [Result] {
    var values: [Result] = []
    for element in self {
      values.append(try await transform(element))
    }
    return values
  }
}
