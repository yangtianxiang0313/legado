import LegadoCore

public struct BookSourceDTO: LosslessSourceDocument {
  private static let knownFieldNames = Set(BookSourceSchema.bookSourceFields.map(\.jsonName))
  private let storage: SourceObjectStorage

  public init(jsonValue: JSONValue) throws {
    self.storage = try SourceObjectStorage(jsonValue: jsonValue)
  }

  public var bookSourceUrl: SourceField<String> { storage.string("bookSourceUrl") }
  public var bookSourceName: SourceField<String> { storage.string("bookSourceName") }
  public var bookSourceGroup: SourceField<String> { storage.string("bookSourceGroup") }
  public var bookSourceType: SourceField<Int32> { storage.int32("bookSourceType") }
  public var bookUrlPattern: SourceField<String> { storage.string("bookUrlPattern") }
  public var customOrder: SourceField<Int32> { storage.int32("customOrder") }
  public var enabled: SourceField<Bool> { storage.boolean("enabled") }
  public var enabledExplore: SourceField<Bool> { storage.boolean("enabledExplore") }
  public var jsLib: SourceField<String> { storage.string("jsLib") }
  public var enabledCookieJar: SourceField<Bool> { storage.boolean("enabledCookieJar") }
  public var concurrentRate: SourceField<String> { storage.string("concurrentRate") }
  public var header: SourceField<String> { storage.string("header") }
  public var loginUrl: SourceField<String> { storage.string("loginUrl") }
  public var loginUi: SourceField<String> { storage.string("loginUi") }
  public var loginCheckJs: SourceField<String> { storage.string("loginCheckJs") }
  public var coverDecodeJs: SourceField<String> { storage.string("coverDecodeJs") }
  public var bookSourceComment: SourceField<String> { storage.string("bookSourceComment") }
  public var variableComment: SourceField<String> { storage.string("variableComment") }
  public var lastUpdateTime: SourceField<Int64> { storage.int64("lastUpdateTime") }
  public var respondTime: SourceField<Int64> { storage.int64("respondTime") }
  public var weight: SourceField<Int32> { storage.int32("weight") }
  public var exploreUrl: SourceField<String> { storage.string("exploreUrl") }
  public var exploreScreen: SourceField<String> { storage.string("exploreScreen") }
  public var searchUrl: SourceField<String> { storage.string("searchUrl") }

  public var ruleExplore: SourceField<ExploreRuleDTO> {
    storage.object("ruleExplore") { ExploreRuleDTO(fields: $0) }
  }

  public var ruleSearch: SourceField<SearchRuleDTO> {
    storage.object("ruleSearch") { SearchRuleDTO(fields: $0) }
  }

  public var ruleBookInfo: SourceField<BookInfoRuleDTO> {
    storage.object("ruleBookInfo") { BookInfoRuleDTO(fields: $0) }
  }

  public var ruleToc: SourceField<TocRuleDTO> {
    storage.object("ruleToc") { TocRuleDTO(fields: $0) }
  }

  public var ruleContent: SourceField<ContentRuleDTO> {
    storage.object("ruleContent") { ContentRuleDTO(fields: $0) }
  }

  public var ruleReview: SourceField<ReviewRuleDTO> {
    storage.object("ruleReview") { ReviewRuleDTO(fields: $0) }
  }

  public var jsonValue: JSONValue { storage.jsonValue }
  public var rawFields: [String: JSONValue] { storage.fields }
  public var unknownFields: [String: JSONValue] {
    storage.unknownFields(excluding: Self.knownFieldNames)
  }

  public func rawValue(for jsonName: String) -> JSONValue? {
    storage.rawValue(for: jsonName)
  }
}
