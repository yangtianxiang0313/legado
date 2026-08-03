import Foundation
import Observation
import RuleRuntime
import SourceRuntime

public struct RSSSource: Codable, Identifiable, Equatable, Sendable {
  public var id: String { sourceURL }
  public var sourceURL: String
  public var sourceName: String
  public var sourceIcon: String
  public var sourceGroup: String?
  public var sourceComment: String?
  public var enabled: Bool
  public var variableComment: String?
  public var jsLib: String?
  public var enabledCookieJar: Bool?
  public var concurrentRate: String?
  public var header: String?
  public var loginURL: String?
  public var loginUI: String?
  public var loginCheckJS: String?
  public var coverDecodeJS: String?
  public var sortURL: String?
  public var singleURL: Bool
  public var articleStyle: Int
  public var ruleArticles: String?
  public var ruleNextPage: String?
  public var ruleTitle: String?
  public var rulePubDate: String?
  public var ruleDescription: String?
  public var ruleImage: String?
  public var ruleLink: String?
  public var ruleContent: String?
  public var contentWhitelist: String?
  public var contentBlacklist: String?
  public var shouldOverrideURLLoading: String?
  public var style: String?
  public var enableJS: Bool
  public var loadWithBaseURL: Bool
  public var injectJS: String?
  public var lastUpdateTime: Int64
  public var customOrder: Int

  public init(
    sourceURL: String,
    sourceName: String = "",
    sourceIcon: String = "",
    sourceGroup: String? = nil,
    sourceComment: String? = nil,
    enabled: Bool = true,
    variableComment: String? = nil,
    jsLib: String? = nil,
    enabledCookieJar: Bool? = true,
    concurrentRate: String? = nil,
    header: String? = nil,
    loginURL: String? = nil,
    loginUI: String? = nil,
    loginCheckJS: String? = nil,
    coverDecodeJS: String? = nil,
    sortURL: String? = nil,
    singleURL: Bool = false,
    articleStyle: Int = 0,
    ruleArticles: String? = nil,
    ruleNextPage: String? = nil,
    ruleTitle: String? = nil,
    rulePubDate: String? = nil,
    ruleDescription: String? = nil,
    ruleImage: String? = nil,
    ruleLink: String? = nil,
    ruleContent: String? = nil,
    contentWhitelist: String? = nil,
    contentBlacklist: String? = nil,
    shouldOverrideURLLoading: String? = nil,
    style: String? = nil,
    enableJS: Bool = true,
    loadWithBaseURL: Bool = true,
    injectJS: String? = nil,
    lastUpdateTime: Int64 = 0,
    customOrder: Int = 0
  ) {
    self.sourceURL = sourceURL
    self.sourceName = sourceName
    self.sourceIcon = sourceIcon
    self.sourceGroup = sourceGroup
    self.sourceComment = sourceComment
    self.enabled = enabled
    self.variableComment = variableComment
    self.jsLib = jsLib
    self.enabledCookieJar = enabledCookieJar
    self.concurrentRate = concurrentRate
    self.header = header
    self.loginURL = loginURL
    self.loginUI = loginUI
    self.loginCheckJS = loginCheckJS
    self.coverDecodeJS = coverDecodeJS
    self.sortURL = sortURL
    self.singleURL = singleURL
    self.articleStyle = articleStyle
    self.ruleArticles = ruleArticles
    self.ruleNextPage = ruleNextPage
    self.ruleTitle = ruleTitle
    self.rulePubDate = rulePubDate
    self.ruleDescription = ruleDescription
    self.ruleImage = ruleImage
    self.ruleLink = ruleLink
    self.ruleContent = ruleContent
    self.contentWhitelist = contentWhitelist
    self.contentBlacklist = contentBlacklist
    self.shouldOverrideURLLoading = shouldOverrideURLLoading
    self.style = style
    self.enableJS = enableJS
    self.loadWithBaseURL = loadWithBaseURL
    self.injectJS = injectJS
    self.lastUpdateTime = lastUpdateTime
    self.customOrder = customOrder
  }
}

public struct RSSStar: Codable, Identifiable, Equatable, Sendable {
  public var id: String { origin + "\u{0}" + link }
  public var origin: String
  public var sort: String
  public var title: String
  public var starTime: Int64
  public var link: String
  public var pubDate: String?
  public var description: String?
  public var content: String?
  public var image: String?
  public var variable: String?

  public init(
    origin: String,
    sort: String = "",
    title: String = "",
    starTime: Int64 = 0,
    link: String,
    pubDate: String? = nil,
    description: String? = nil,
    content: String? = nil,
    image: String? = nil,
    variable: String? = nil
  ) {
    self.origin = origin
    self.sort = sort
    self.title = title
    self.starTime = starTime
    self.link = link
    self.pubDate = pubDate
    self.description = description
    self.content = content
    self.image = image
    self.variable = variable
  }
}

public protocol RSSRepository: Sendable {
  func rssSources() async throws -> [RSSSource]
  func rssStars() async throws -> [RSSStar]
  func upsertRSSSource(_ source: RSSSource) async throws
  func upsertRSSStar(_ star: RSSStar) async throws
  func deleteRSSStar(origin: String, link: String) async throws
}

@MainActor
@Observable
public final class RSSStore {
  public private(set) var sources: [RSSSource] = []
  public private(set) var stars: [RSSStar] = []
  public private(set) var errorMessage: String?

  private let repository: any RSSRepository

  public init(repository: any RSSRepository) {
    self.repository = repository
  }

  public func reload() async {
    do {
      async let sources = repository.rssSources()
      async let stars = repository.rssStars()
      self.sources = try await sources
      self.stars = try await stars
      errorMessage = nil
    } catch {
      errorMessage = "无法读取 RSS 数据"
    }
  }

  public func isStarred(_ article: RSSArticleItem) -> Bool {
    stars.contains { $0.origin == article.origin && $0.link == article.link }
  }

  public func toggleStar(_ article: RSSArticleItem) async {
    do {
      if isStarred(article) {
        try await repository.deleteRSSStar(
          origin: article.origin,
          link: article.link
        )
      } else {
        try await repository.upsertRSSStar(
          RSSStar(
            origin: article.origin,
            sort: article.sort,
            title: article.title,
            starTime: Int64(Date().timeIntervalSince1970 * 1_000),
            link: article.link,
            pubDate: article.pubDate,
            description: article.description,
            content: article.content,
            image: article.image
          )
        )
      }
      await reload()
    } catch {
      errorMessage = "无法更新 RSS 收藏"
    }
  }
}

public struct RSSArticleItem: Identifiable, Equatable, Sendable {
  public var id: String { origin + "\u{0}" + link }
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

public protocol RSSContentLoading: Sendable {
  func load(source: RSSSource, article: RSSArticleItem) async throws -> String?
}

public struct SourceRuntimeRSSContentLoader: RSSContentLoading, Sendable {
  private let transport: any HTTPTransport
  private let cookieStore: SourceCookieStore
  private let dynamicWebPagePort: (any SourceDynamicWebPagePort)?
  private let htmlSelectorBackend: (any HTMLSelectorBackend)?

  public init(
    transport: any HTTPTransport,
    cookieStore: SourceCookieStore = SourceCookieStore(),
    dynamicWebPagePort: (any SourceDynamicWebPagePort)? = nil,
    htmlSelectorBackend: (any HTMLSelectorBackend)? = nil
  ) {
    self.transport = transport
    self.cookieStore = cookieStore
    self.dynamicWebPagePort = dynamicWebPagePort
    self.htmlSelectorBackend = htmlSelectorBackend
  }

  public func load(
    source: RSSSource,
    article: RSSArticleItem
  ) async throws -> String? {
    if let description = article.description, !description.isEmpty {
      return description
    }
    guard let ruleContent = source.ruleContent, !ruleContent.isEmpty else {
      return nil
    }
    return try await RSSContentPipeline(
      definition: RSSRuntimeDefinition(
        sourceURL: source.sourceURL,
        sourceHeaders: try sourceHeaders(source.header),
        enabledCookieJar: source.enabledCookieJar ?? true
      ),
      transport: transport,
      cookieStore: cookieStore,
      dynamicWebPagePort: dynamicWebPagePort,
      htmlSelectorBackend: htmlSelectorBackend
    ).load(articleURL: article.link, ruleContent: ruleContent)
  }

  private func sourceHeaders(_ value: String?) throws -> [SourceHeaderField] {
    guard let value, !value.isEmpty else { return [] }
    let object = try JSONDecoder().decode(
      [String: String].self,
      from: Data(value.utf8)
    )
    return try object.sorted { $0.key < $1.key }.map {
      try SourceHeaderField(name: $0.key, value: $0.value)
    }
  }
}

@MainActor
@Observable
public final class RSSReadSession {
  public private(set) var content: String?
  public private(set) var isLoading = false
  public private(set) var errorMessage: String?
  private let loader: any RSSContentLoading

  public init(loader: any RSSContentLoading) { self.loader = loader }

  public func load(source: RSSSource, article: RSSArticleItem) async {
    isLoading = true
    defer { isLoading = false }
    do {
      content = try await loader.load(source: source, article: article)
      errorMessage = nil
    } catch {
      content = nil
      errorMessage = "加载正文失败"
    }
  }
}

public struct RSSArticlePage: Equatable, Sendable {
  public let articles: [RSSArticleItem]
  public let nextPageURL: String?
}

public protocol RSSArticleLoading: Sendable {
  func load(
    source: RSSSource,
    sortName: String,
    sortURL: String,
    page: Int
  ) async throws -> RSSArticlePage
}

public struct SourceRuntimeRSSArticleLoader: RSSArticleLoading, Sendable {
  private let transport: any HTTPTransport
  private let cookieStore: SourceCookieStore
  private let dynamicWebPagePort: (any SourceDynamicWebPagePort)?
  private let htmlSelectorBackend: (any HTMLSelectorBackend)?

  public init(
    transport: any HTTPTransport,
    cookieStore: SourceCookieStore = SourceCookieStore(),
    dynamicWebPagePort: (any SourceDynamicWebPagePort)? = nil,
    htmlSelectorBackend: (any HTMLSelectorBackend)? = nil
  ) {
    self.transport = transport
    self.cookieStore = cookieStore
    self.dynamicWebPagePort = dynamicWebPagePort
    self.htmlSelectorBackend = htmlSelectorBackend
  }

  public func load(
    source: RSSSource,
    sortName: String,
    sortURL: String,
    page: Int
  ) async throws -> RSSArticlePage {
    let headers = try sourceHeaders(source.header)
    let result = try await RSSArticlePipeline(
      definition: RSSRuntimeDefinition(
        sourceURL: source.sourceURL,
        sourceHeaders: headers,
        enabledCookieJar: source.enabledCookieJar ?? true,
        ruleArticles: source.ruleArticles,
        ruleNextPage: source.ruleNextPage,
        ruleTitle: source.ruleTitle,
        rulePubDate: source.rulePubDate,
        ruleDescription: source.ruleDescription,
        ruleImage: source.ruleImage,
        ruleLink: source.ruleLink
      ),
      transport: transport,
      cookieStore: cookieStore,
      dynamicWebPagePort: dynamicWebPagePort,
      htmlSelectorBackend: htmlSelectorBackend
    ).load(sortName: sortName, sortURL: sortURL, page: page)
    return RSSArticlePage(
      articles: result.articles.map {
        RSSArticleItem(
          origin: $0.origin,
          sort: $0.sort,
          title: $0.title,
          link: $0.link,
          pubDate: $0.pubDate,
          description: $0.description,
          content: $0.content,
          image: $0.image
        )
      },
      nextPageURL: result.nextPageURL
    )
  }

  private func sourceHeaders(_ value: String?) throws -> [SourceHeaderField] {
    guard let value, !value.isEmpty else { return [] }
    let object = try JSONDecoder().decode(
      [String: String].self,
      from: Data(value.utf8)
    )
    return try object.sorted { $0.key < $1.key }.map {
      try SourceHeaderField(name: $0.key, value: $0.value)
    }
  }
}

@MainActor
@Observable
public final class RSSArticleSession {
  public private(set) var articles: [RSSArticleItem] = []
  public private(set) var isLoading = false
  public private(set) var hasMore = false
  public private(set) var errorMessage: String?

  private let loader: any RSSArticleLoading
  private var source: RSSSource?
  private var sortName = ""
  private var nextPageURL: String?
  private var page = 0

  public init(loader: any RSSArticleLoading) {
    self.loader = loader
  }

  public func load(source: RSSSource) async {
    self.source = source
    sortName = source.sourceName
    page = 1
    articles = []
    await loadPage(url: source.sortURL ?? source.sourceURL, appending: false)
  }

  public func loadMore() async {
    guard let nextPageURL else { return }
    page += 1
    await loadPage(url: nextPageURL, appending: true)
  }

  private func loadPage(url: String, appending: Bool) async {
    guard let source else { return }
    isLoading = true
    defer { isLoading = false }
    do {
      let result = try await loader.load(
        source: source,
        sortName: sortName,
        sortURL: url,
        page: page
      )
      articles = appending ? articles + result.articles : result.articles
      nextPageURL = result.nextPageURL
      hasMore = !result.articles.isEmpty && result.nextPageURL != nil
      errorMessage = nil
    } catch {
      hasMore = false
      errorMessage = "无法加载 RSS 文章"
    }
  }
}
