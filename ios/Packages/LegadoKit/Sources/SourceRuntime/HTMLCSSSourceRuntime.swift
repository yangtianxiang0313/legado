import Foundation

public struct HTMLCSSRule: Sendable, Equatable {
  public enum Value: String, Sendable {
    case text
    case href
    case src
    case html
  }

  public let selector: String
  public let value: Value

  public init(_ selector: String, value: Value = .text) {
    self.selector = selector
    self.value = value
  }
}

public struct SearchRules: Sendable, Equatable {
  public let list: String
  public let name: HTMLCSSRule
  public let author: HTMLCSSRule
  public let intro: HTMLCSSRule
  public let kind: HTMLCSSRule
  public let lastChapter: HTMLCSSRule
  public let bookURL: HTMLCSSRule
  public let coverURL: HTMLCSSRule

  public init(
    list: String,
    name: HTMLCSSRule,
    author: HTMLCSSRule,
    intro: HTMLCSSRule,
    kind: HTMLCSSRule,
    lastChapter: HTMLCSSRule,
    bookURL: HTMLCSSRule,
    coverURL: HTMLCSSRule
  ) {
    self.list = list
    self.name = name
    self.author = author
    self.intro = intro
    self.kind = kind
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
  public let lastChapter: HTMLCSSRule
  public let coverURL: HTMLCSSRule
  public let tocURL: HTMLCSSRule

  public init(
    name: HTMLCSSRule,
    author: HTMLCSSRule,
    intro: HTMLCSSRule,
    kind: HTMLCSSRule,
    lastChapter: HTMLCSSRule,
    coverURL: HTMLCSSRule,
    tocURL: HTMLCSSRule
  ) {
    self.name = name
    self.author = author
    self.intro = intro
    self.kind = kind
    self.lastChapter = lastChapter
    self.coverURL = coverURL
    self.tocURL = tocURL
  }
}

public struct TOCRules: Sendable, Equatable {
  public let list: String
  public let name: HTMLCSSRule
  public let url: HTMLCSSRule

  public init(list: String, name: HTMLCSSRule, url: HTMLCSSRule) {
    self.list = list
    self.name = name
    self.url = url
  }
}

public struct ContentRules: Sendable, Equatable {
  public let content: HTMLCSSRule

  public init(content: HTMLCSSRule) {
    self.content = content
  }
}

public struct HTMLCSSSourceDefinition: Sendable, Equatable {
  public let searchURLTemplate: String
  public let search: SearchRules
  public let bookInfo: BookInfoRules
  public let toc: TOCRules
  public let content: ContentRules

  public init(
    searchURLTemplate: String,
    search: SearchRules,
    bookInfo: BookInfoRules,
    toc: TOCRules,
    content: ContentRules
  ) {
    self.searchURLTemplate = searchURLTemplate
    self.search = search
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
  public let lastChapter: String?
  public let bookURL: URL
  public let coverURL: URL?
  public let tocURL: URL?
}

public struct SourceChapter: Sendable, Equatable {
  public let index: Int
  public let title: String
  public let url: URL
  public let isPay: Bool
  public let isVIP: Bool
  public let isVolume: Bool
}

public struct SourceContent: Sendable, Equatable {
  public let chapterURL: URL
  public let content: String
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

  public init(definition: HTMLCSSSourceDefinition) {
    self.definition = definition
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
    return try document.select(definition.search.list).compactMap { node in
      guard
        let name = try value(definition.search.name, in: node, document: document),
        let book = try resolved(definition.search.bookURL, in: node, document: document, base: responseURL)
      else { return nil }
      return SourceBook(
        name: name,
        author: try value(definition.search.author, in: node, document: document),
        intro: try value(definition.search.intro, in: node, document: document),
        kind: try value(definition.search.kind, in: node, document: document),
        lastChapter: try value(definition.search.lastChapter, in: node, document: document),
        bookURL: book,
        coverURL: try resolved(definition.search.coverURL, in: node, document: document, base: responseURL),
        tocURL: nil
      )
    }
  }

  public func bookInfo(html: String, bookURL: URL) throws -> SourceBook {
    let document = try parse(html)
    guard
      let name = try value(definition.bookInfo.name, in: document.root, document: document),
      let toc = try resolved(definition.bookInfo.tocURL, in: document.root, document: document, base: bookURL)
    else { throw SourceRuntimeIssue(stage: .fieldEvaluation, code: .ruleFailed) }
    return SourceBook(
      name: name,
      author: try value(definition.bookInfo.author, in: document.root, document: document),
      intro: try value(definition.bookInfo.intro, in: document.root, document: document),
      kind: try value(definition.bookInfo.kind, in: document.root, document: document),
      lastChapter: try value(definition.bookInfo.lastChapter, in: document.root, document: document),
      bookURL: bookURL,
      coverURL: try resolved(definition.bookInfo.coverURL, in: document.root, document: document, base: bookURL),
      tocURL: toc
    )
  }

  public func chapters(html: String, tocURL: URL) throws -> [SourceChapter] {
    let document = try parse(html)
    let nodes = try document.select(definition.toc.list)
    guard !nodes.isEmpty else {
      throw SourceRuntimeIssue(stage: .fieldEvaluation, code: .ruleFailed)
    }
    return try nodes.enumerated().map { index, node in
      guard
        let title = try value(definition.toc.name, in: node, document: document),
        let url = try resolved(definition.toc.url, in: node, document: document, base: tocURL)
      else { throw SourceRuntimeIssue(stage: .fieldEvaluation, code: .ruleFailed) }
      return SourceChapter(
        index: index,
        title: title,
        url: url,
        isPay: false,
        isVIP: false,
        isVolume: false
      )
    }
  }

  public func content(html: String, chapterURL: URL) throws -> SourceContent {
    let document = try parse(html)
    guard let node = try document.select(definition.content.content.selector).first else {
      throw SourceRuntimeIssue(stage: .fieldEvaluation, code: .ruleFailed)
    }
    let lines = node.children.compactMap { child -> String? in
      switch child.name {
      case "p":
        let text = child.normalizedText
        return text.isEmpty ? nil : "　　" + text
      case "img":
        guard let raw = child.attributes["src"], let url = URL(string: raw, relativeTo: chapterURL)?.absoluteURL else {
          return nil
        }
        return "　　<img src=\"\(url.absoluteString)\">"
      default:
        let text = child.normalizedText
        return text.isEmpty ? nil : "　　" + text
      }
    }
    guard !lines.isEmpty else {
      throw SourceRuntimeIssue(stage: .fieldEvaluation, code: .ruleFailed)
    }
    return SourceContent(chapterURL: chapterURL, content: lines.joined(separator: "\n"))
  }

  private func parse(_ html: String) throws -> HTMLDocument {
    do { return try HTMLDocument(html: html) }
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
    guard let match = try document.select(rule.selector, within: node).first else { return nil }
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
}
