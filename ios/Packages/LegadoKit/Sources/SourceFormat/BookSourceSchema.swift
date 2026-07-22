public enum SourceFieldKind: String, Equatable, Sendable {
  case string
  case int32
  case int64
  case boolean
  case object
}

public struct SourceFieldDefinition: Equatable, Sendable {
  public let jsonName: String
  public let kind: SourceFieldKind
  public let nullable: Bool

  public init(jsonName: String, kind: SourceFieldKind, nullable: Bool) {
    self.jsonName = jsonName
    self.kind = kind
    self.nullable = nullable
  }
}

public enum BookSourceSchema {
  public static let bookSourceFields: [SourceFieldDefinition] = [
    field("bookSourceUrl", .string, false),
    field("bookSourceName", .string, false),
    field("bookSourceGroup", .string, true),
    field("bookSourceType", .int32, false),
    field("bookUrlPattern", .string, true),
    field("customOrder", .int32, false),
    field("enabled", .boolean, false),
    field("enabledExplore", .boolean, false),
    field("jsLib", .string, true),
    field("enabledCookieJar", .boolean, true),
    field("concurrentRate", .string, true),
    field("header", .string, true),
    field("loginUrl", .string, true),
    field("loginUi", .string, true),
    field("loginCheckJs", .string, true),
    field("coverDecodeJs", .string, true),
    field("bookSourceComment", .string, true),
    field("variableComment", .string, true),
    field("lastUpdateTime", .int64, false),
    field("respondTime", .int64, false),
    field("weight", .int32, false),
    field("exploreUrl", .string, true),
    field("exploreScreen", .string, true),
    field("ruleExplore", .object, true),
    field("searchUrl", .string, true),
    field("ruleSearch", .object, true),
    field("ruleBookInfo", .object, true),
    field("ruleToc", .object, true),
    field("ruleContent", .object, true),
    field("ruleReview", .object, true),
  ]

  public static let searchRuleFields = nullableStrings([
    "checkKeyWord", "bookList", "name", "author", "intro", "kind", "lastChapter",
    "updateTime", "bookUrl", "coverUrl", "wordCount",
  ])

  public static let exploreRuleFields = nullableStrings([
    "bookList", "name", "author", "intro", "kind", "lastChapter", "updateTime",
    "bookUrl", "coverUrl", "wordCount",
  ])

  public static let bookInfoRuleFields = nullableStrings([
    "init", "name", "author", "intro", "kind", "lastChapter", "updateTime", "coverUrl",
    "tocUrl", "wordCount", "canReName", "downloadUrls",
  ])

  public static let tocRuleFields = nullableStrings([
    "preUpdateJs", "chapterList", "chapterName", "chapterUrl", "formatJs", "isVolume",
    "isVip", "isPay", "updateTime", "nextTocUrl",
  ])

  public static let contentRuleFields = nullableStrings([
    "content", "title", "nextContentUrl", "webJs", "sourceRegex", "replaceRegex",
    "imageStyle", "imageDecode", "payAction",
  ])

  public static let reviewRuleFields = nullableStrings([
    "reviewUrl", "avatarRule", "contentRule", "postTimeRule", "reviewQuoteUrl", "voteUpUrl",
    "voteDownUrl", "postReviewUrl", "postQuoteUrl", "deleteUrl",
  ])

  private static func field(
    _ jsonName: String,
    _ kind: SourceFieldKind,
    _ nullable: Bool
  ) -> SourceFieldDefinition {
    SourceFieldDefinition(jsonName: jsonName, kind: kind, nullable: nullable)
  }

  private static func nullableStrings(_ names: [String]) -> [SourceFieldDefinition] {
    names.map { field($0, .string, true) }
  }
}
