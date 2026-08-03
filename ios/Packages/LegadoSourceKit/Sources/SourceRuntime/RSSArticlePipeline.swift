import Foundation
import LegadoCore
import RuleRuntime

public struct RSSRuntimeDefinition: Equatable, Sendable {
  public let sourceURL: String
  public let sourceHeaders: [SourceHeaderField]
  public let enabledCookieJar: Bool
  public let ruleArticles: String?
  public let ruleNextPage: String?
  public let ruleTitle: String?
  public let rulePubDate: String?
  public let ruleDescription: String?
  public let ruleImage: String?
  public let ruleLink: String?

  public init(
    sourceURL: String,
    sourceHeaders: [SourceHeaderField] = [],
    enabledCookieJar: Bool = true,
    ruleArticles: String? = nil,
    ruleNextPage: String? = nil,
    ruleTitle: String? = nil,
    rulePubDate: String? = nil,
    ruleDescription: String? = nil,
    ruleImage: String? = nil,
    ruleLink: String? = nil
  ) {
    self.sourceURL = sourceURL
    self.sourceHeaders = sourceHeaders
    self.enabledCookieJar = enabledCookieJar
    self.ruleArticles = ruleArticles
    self.ruleNextPage = ruleNextPage
    self.ruleTitle = ruleTitle
    self.rulePubDate = rulePubDate
    self.ruleDescription = ruleDescription
    self.ruleImage = ruleImage
    self.ruleLink = ruleLink
  }
}

public struct RSSRuntimeArticle: Equatable, Sendable {
  public let origin: String
  public let sort: String
  public let title: String
  public let link: String
  public let pubDate: String?
  public let description: String?
  public let content: String?
  public let image: String?

  public init(
    origin: String,
    sort: String,
    title: String,
    link: String,
    pubDate: String? = nil,
    description: String? = nil,
    content: String? = nil,
    image: String? = nil
  ) {
    self.origin = origin
    self.sort = sort
    self.title = title
    self.link = link
    self.pubDate = pubDate
    self.description = description
    self.content = content
    self.image = image
  }
}

public struct RSSRuntimePage: Equatable, Sendable {
  public let articles: [RSSRuntimeArticle]
  public let nextPageURL: String?
  public let requestPlan: SourceRequestPlan
  public let finalURL: HTTPURL

  public init(
    articles: [RSSRuntimeArticle],
    nextPageURL: String?,
    requestPlan: SourceRequestPlan,
    finalURL: HTTPURL
  ) {
    self.articles = articles
    self.nextPageURL = nextPageURL
    self.requestPlan = requestPlan
    self.finalURL = finalURL
  }
}

public enum RSSArticlePipelineError: Error, Equatable, Sendable {
  case emptyBody
  case malformedDefaultFeed
}

public struct RSSContentPipeline: Sendable {
  private let definition: RSSRuntimeDefinition
  private let responseSession: SourceStringResponseSession
  private let htmlSelectorBackend: (any HTMLSelectorBackend)?

  public init(
    definition: RSSRuntimeDefinition,
    transport: any HTTPTransport,
    cookieStore: SourceCookieStore = SourceCookieStore(),
    dynamicWebPagePort: (any SourceDynamicWebPagePort)? = nil,
    htmlSelectorBackend: (any HTMLSelectorBackend)? = nil
  ) {
    self.definition = definition
    responseSession = SourceStringResponseSession(
      transport: transport,
      cookieStore: cookieStore,
      dynamicWebPagePort: dynamicWebPagePort
    )
    self.htmlSelectorBackend = htmlSelectorBackend
  }

  public func load(
    articleURL: String,
    ruleContent: String
  ) async throws -> String {
    let compilation = try SourceURLTemplateCompiler.compile(
      SourceURLTemplateInput(
        template: articleURL,
        baseURL: definition.sourceURL
      )
    )
    let optionHeaders = try compilation.plan.optionHeaders.isEmpty
      ? compilation.plan.request.headers.fields.map {
        try SourceHeaderField(name: $0.name, value: $0.value)
      }
      : compilation.plan.optionHeaders
    let prepared = try SourceRequestPreparer.prepare(
      request: compilation.plan.request,
      inheritedHeaders: definition.sourceHeaders,
      optionHeaders: optionHeaders,
      persistentCookie: "",
      enabledCookieJar: false,
      retry: compilation.plan.retry
    )
    let plan = SourceRequestPlan(
      request: prepared.constructedRequest,
      body: compilation.plan.body,
      formFields: compilation.plan.formFields,
      optionHeaders: optionHeaders,
      retry: compilation.plan.retry,
      useWebView: compilation.plan.useWebView,
      webJS: compilation.plan.webJS
    )
    let response = try await responseSession.load(
      plan,
      enabledCookieJar: definition.enabledCookieJar
    )
    return try SourceRuleConsumerEvaluator(
      content: response.body,
      htmlSelectorBackend: htmlSelectorBackend
    ).getString(ruleContent)
  }
}

public struct RSSArticlePipeline: Sendable {
  private let definition: RSSRuntimeDefinition
  private let responseSession: SourceStringResponseSession
  private let htmlSelectorBackend: (any HTMLSelectorBackend)?

  public init(
    definition: RSSRuntimeDefinition,
    transport: any HTTPTransport,
    cookieStore: SourceCookieStore = SourceCookieStore(),
    dynamicWebPagePort: (any SourceDynamicWebPagePort)? = nil,
    htmlSelectorBackend: (any HTMLSelectorBackend)? = nil
  ) {
    self.definition = definition
    responseSession = SourceStringResponseSession(
      transport: transport,
      cookieStore: cookieStore,
      dynamicWebPagePort: dynamicWebPagePort
    )
    self.htmlSelectorBackend = htmlSelectorBackend
  }

  public func load(
    sortName: String,
    sortURL: String,
    page: Int
  ) async throws -> RSSRuntimePage {
    let compilation = try SourceURLTemplateCompiler.compile(
      SourceURLTemplateInput(
        template: sortURL,
        page: page,
        baseURL: definition.sourceURL
      )
    )
    let requestPlan = try prepared(compilation.plan)
    let response = try await responseSession.load(
      requestPlan,
      enabledCookieJar: definition.enabledCookieJar
    )
    guard !response.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw RSSArticlePipelineError.emptyBody
    }
    let finalURL = URL(string: response.finalURL.absoluteString)!
    let parsed = try parse(
      body: response.body,
      sortName: sortName,
      sortURL: sortURL,
      finalURL: finalURL
    )
    return RSSRuntimePage(
      articles: parsed.articles,
      nextPageURL: parsed.nextPageURL,
      requestPlan: requestPlan,
      finalURL: response.finalURL
    )
  }

  private func prepared(_ plan: SourceRequestPlan) throws -> SourceRequestPlan {
    let optionHeaders = try plan.optionHeaders.isEmpty
      ? plan.request.headers.fields.map {
        try SourceHeaderField(name: $0.name, value: $0.value)
      }
      : plan.optionHeaders
    let prepared = try SourceRequestPreparer.prepare(
      request: plan.request,
      inheritedHeaders: definition.sourceHeaders,
      optionHeaders: optionHeaders,
      persistentCookie: "",
      enabledCookieJar: false,
      retry: plan.retry
    )
    return SourceRequestPlan(
      request: prepared.constructedRequest,
      body: plan.body,
      formFields: plan.formFields,
      optionHeaders: optionHeaders,
      retry: plan.retry,
      useWebView: plan.useWebView,
      webJS: plan.webJS
    )
  }

  private func parse(
    body: String,
    sortName: String,
    sortURL: String,
    finalURL: URL
  ) throws -> (articles: [RSSRuntimeArticle], nextPageURL: String?) {
    guard let rawArticles = definition.ruleArticles,
          !rawArticles.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return (
        try DefaultRSSParser.parse(
          body,
          origin: definition.sourceURL,
          sort: sortName
        ),
        nil
      )
    }

    let reverse = rawArticles.hasPrefix("-")
    let articleRule = reverse ? String(rawArticles.dropFirst()) : rawArticles
    let root = SourceRuleConsumerEvaluator(
      content: body,
      htmlSelectorBackend: htmlSelectorBackend
    )
    let elements = try root.getElements(articleRule)
    let nextPageURL: String?
    if let rule = definition.ruleNextPage, !rule.isEmpty {
      if rule.uppercased() == "PAGE" {
        nextPageURL = sortURL
      } else {
        let context = SourceRuleURLContext(
          baseURL: sortURL,
          redirectURL: finalURL
        )
        let value = try root.getString(rule, isURL: true, urlContext: context)
        nextPageURL = value.isEmpty ? nil : value
      }
    } else {
      nextPageURL = nil
    }

    let linkBase = URL(string: definition.sourceURL) ?? finalURL
    let fieldContext = SourceRuleURLContext(
      baseURL: definition.sourceURL,
      redirectURL: finalURL
    )
    var articles = try elements.compactMap { element -> RSSRuntimeArticle? in
      let content = try contentString(element)
      let item = SourceRuleConsumerEvaluator(
        content: content,
        htmlSelectorBackend: htmlSelectorBackend
      )
      let title = try item.getString(definition.ruleTitle)
      guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return nil
      }
      let rawLink = try item.getString(definition.ruleLink)
      let link = URL(string: rawLink, relativeTo: linkBase)?.absoluteURL.absoluteString
        ?? rawLink
      let image = try item.getString(
        definition.ruleImage,
        isURL: true,
        urlContext: fieldContext
      )
      return RSSRuntimeArticle(
        origin: definition.sourceURL,
        sort: sortName,
        title: title,
        link: link,
        pubDate: optional(try item.getString(definition.rulePubDate)),
        description: definition.ruleDescription?.isEmpty == false
          ? optional(try item.getString(definition.ruleDescription))
          : nil,
        image: optional(image)
      )
    }
    if reverse { articles.reverse() }
    return (articles, nextPageURL)
  }

  private func contentString(_ value: JSONValue) throws -> String {
    if case .string(let value) = value { return value }
    return String(decoding: try JSONValueCodec.encode(value), as: UTF8.self)
  }

  private func optional(_ value: String) -> String? {
    value.isEmpty ? nil : value
  }
}

private final class DefaultRSSParser: NSObject, XMLParserDelegate {
  private struct Draft {
    var title = ""
    var link = ""
    var pubDate: String?
    var description: String?
    var content: String?
    var image: String?
  }

  private let origin: String
  private let sort: String
  private var insideItem = false
  private var element = ""
  private var text = ""
  private var draft = Draft()
  private(set) var articles: [RSSRuntimeArticle] = []

  private init(origin: String, sort: String) {
    self.origin = origin
    self.sort = sort
  }

  static func parse(
    _ body: String,
    origin: String,
    sort: String
  ) throws -> [RSSRuntimeArticle] {
    let delegate = DefaultRSSParser(origin: origin, sort: sort)
    let parser = XMLParser(data: Data(body.utf8))
    parser.shouldProcessNamespaces = false
    parser.delegate = delegate
    guard parser.parse() else { throw RSSArticlePipelineError.malformedDefaultFeed }
    return delegate.articles
  }

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String] = [:]
  ) {
    let name = (qName ?? elementName).lowercased()
    if name == "item" {
      insideItem = true
      draft = Draft()
    }
    guard insideItem else { return }
    element = name
    text = ""
    if name == "media:thumbnail" {
      draft.image = attributeDict["url"]
    } else if name == "enclosure",
              attributeDict["type"]?.contains("image/") == true {
      draft.image = attributeDict["url"]
    }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    guard insideItem else { return }
    text += string
  }

  func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    let name = (qName ?? elementName).lowercased()
    guard insideItem else { return }
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    switch name {
    case "title": draft.title = value
    case "link": draft.link = value
    case "pubdate", "time": draft.pubDate = value
    case "description":
      draft.description = value
      draft.image = draft.image ?? imageURL(in: value)
    case "content:encoded":
      draft.content = value
      draft.image = draft.image ?? imageURL(in: value)
    case "item":
      articles.append(
        RSSRuntimeArticle(
          origin: origin,
          sort: sort,
          title: draft.title,
          link: draft.link,
          pubDate: draft.pubDate,
          description: draft.description,
          content: draft.content,
          image: draft.image
        )
      )
      insideItem = false
    default: break
    }
    text = ""
  }

  private func imageURL(in value: String) -> String? {
    guard let regex = try? NSRegularExpression(
      pattern: #"<img\s+[^>]*src\s*=\s*\"([^\"]+)\""#,
      options: [.caseInsensitive]
    ),
    let match = regex.firstMatch(
      in: value,
      range: NSRange(value.startIndex..., in: value)
    ),
    let range = Range(match.range(at: 1), in: value)
    else { return nil }
    return String(value[range]).trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
