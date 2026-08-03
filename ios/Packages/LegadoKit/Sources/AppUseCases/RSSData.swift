import Observation

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
}
