import LegadoCore

public struct SearchRuleDTO: LosslessSourceDocument {
  private static let knownFieldNames = Set(BookSourceSchema.searchRuleFields.map(\.jsonName))
  private let storage: SourceObjectStorage

  public init(jsonValue: JSONValue) throws {
    self.storage = try SourceObjectStorage(jsonValue: jsonValue)
  }

  init(fields: [String: JSONValue]) {
    self.storage = SourceObjectStorage(fields: fields)
  }

  public var checkKeyWord: SourceField<String> { storage.string("checkKeyWord") }
  public var bookList: SourceField<String> { storage.string("bookList") }
  public var name: SourceField<String> { storage.string("name") }
  public var author: SourceField<String> { storage.string("author") }
  public var intro: SourceField<String> { storage.string("intro") }
  public var kind: SourceField<String> { storage.string("kind") }
  public var lastChapter: SourceField<String> { storage.string("lastChapter") }
  public var updateTime: SourceField<String> { storage.string("updateTime") }
  public var bookUrl: SourceField<String> { storage.string("bookUrl") }
  public var coverUrl: SourceField<String> { storage.string("coverUrl") }
  public var wordCount: SourceField<String> { storage.string("wordCount") }

  public var jsonValue: JSONValue { storage.jsonValue }
  public var rawFields: [String: JSONValue] { storage.fields }
  public var unknownFields: [String: JSONValue] {
    storage.unknownFields(excluding: Self.knownFieldNames)
  }

  public func rawValue(for jsonName: String) -> JSONValue? {
    storage.rawValue(for: jsonName)
  }
}

public struct ExploreRuleDTO: LosslessSourceDocument {
  private static let knownFieldNames = Set(BookSourceSchema.exploreRuleFields.map(\.jsonName))
  private let storage: SourceObjectStorage

  public init(jsonValue: JSONValue) throws {
    self.storage = try SourceObjectStorage(jsonValue: jsonValue)
  }

  init(fields: [String: JSONValue]) {
    self.storage = SourceObjectStorage(fields: fields)
  }

  public var bookList: SourceField<String> { storage.string("bookList") }
  public var name: SourceField<String> { storage.string("name") }
  public var author: SourceField<String> { storage.string("author") }
  public var intro: SourceField<String> { storage.string("intro") }
  public var kind: SourceField<String> { storage.string("kind") }
  public var lastChapter: SourceField<String> { storage.string("lastChapter") }
  public var updateTime: SourceField<String> { storage.string("updateTime") }
  public var bookUrl: SourceField<String> { storage.string("bookUrl") }
  public var coverUrl: SourceField<String> { storage.string("coverUrl") }
  public var wordCount: SourceField<String> { storage.string("wordCount") }

  public var jsonValue: JSONValue { storage.jsonValue }
  public var rawFields: [String: JSONValue] { storage.fields }
  public var unknownFields: [String: JSONValue] {
    storage.unknownFields(excluding: Self.knownFieldNames)
  }

  public func rawValue(for jsonName: String) -> JSONValue? {
    storage.rawValue(for: jsonName)
  }
}

public struct BookInfoRuleDTO: LosslessSourceDocument {
  private static let knownFieldNames = Set(BookSourceSchema.bookInfoRuleFields.map(\.jsonName))
  private let storage: SourceObjectStorage

  public init(jsonValue: JSONValue) throws {
    self.storage = try SourceObjectStorage(jsonValue: jsonValue)
  }

  init(fields: [String: JSONValue]) {
    self.storage = SourceObjectStorage(fields: fields)
  }

  public var initialization: SourceField<String> { storage.string("init") }
  public var name: SourceField<String> { storage.string("name") }
  public var author: SourceField<String> { storage.string("author") }
  public var intro: SourceField<String> { storage.string("intro") }
  public var kind: SourceField<String> { storage.string("kind") }
  public var lastChapter: SourceField<String> { storage.string("lastChapter") }
  public var updateTime: SourceField<String> { storage.string("updateTime") }
  public var coverUrl: SourceField<String> { storage.string("coverUrl") }
  public var tocUrl: SourceField<String> { storage.string("tocUrl") }
  public var wordCount: SourceField<String> { storage.string("wordCount") }
  public var canReName: SourceField<String> { storage.string("canReName") }
  public var downloadUrls: SourceField<String> { storage.string("downloadUrls") }

  public var jsonValue: JSONValue { storage.jsonValue }
  public var rawFields: [String: JSONValue] { storage.fields }
  public var unknownFields: [String: JSONValue] {
    storage.unknownFields(excluding: Self.knownFieldNames)
  }

  public func rawValue(for jsonName: String) -> JSONValue? {
    storage.rawValue(for: jsonName)
  }
}

public struct TocRuleDTO: LosslessSourceDocument {
  private static let knownFieldNames = Set(BookSourceSchema.tocRuleFields.map(\.jsonName))
  private let storage: SourceObjectStorage

  public init(jsonValue: JSONValue) throws {
    self.storage = try SourceObjectStorage(jsonValue: jsonValue)
  }

  init(fields: [String: JSONValue]) {
    self.storage = SourceObjectStorage(fields: fields)
  }

  public var preUpdateJs: SourceField<String> { storage.string("preUpdateJs") }
  public var chapterList: SourceField<String> { storage.string("chapterList") }
  public var chapterName: SourceField<String> { storage.string("chapterName") }
  public var chapterUrl: SourceField<String> { storage.string("chapterUrl") }
  public var formatJs: SourceField<String> { storage.string("formatJs") }
  public var isVolume: SourceField<String> { storage.string("isVolume") }
  public var isVip: SourceField<String> { storage.string("isVip") }
  public var isPay: SourceField<String> { storage.string("isPay") }
  public var updateTime: SourceField<String> { storage.string("updateTime") }
  public var nextTocUrl: SourceField<String> { storage.string("nextTocUrl") }

  public var jsonValue: JSONValue { storage.jsonValue }
  public var rawFields: [String: JSONValue] { storage.fields }
  public var unknownFields: [String: JSONValue] {
    storage.unknownFields(excluding: Self.knownFieldNames)
  }

  public func rawValue(for jsonName: String) -> JSONValue? {
    storage.rawValue(for: jsonName)
  }
}

public struct ContentRuleDTO: LosslessSourceDocument {
  private static let knownFieldNames = Set(BookSourceSchema.contentRuleFields.map(\.jsonName))
  private let storage: SourceObjectStorage

  public init(jsonValue: JSONValue) throws {
    self.storage = try SourceObjectStorage(jsonValue: jsonValue)
  }

  init(fields: [String: JSONValue]) {
    self.storage = SourceObjectStorage(fields: fields)
  }

  public var content: SourceField<String> { storage.string("content") }
  public var title: SourceField<String> { storage.string("title") }
  public var nextContentUrl: SourceField<String> { storage.string("nextContentUrl") }
  public var webJs: SourceField<String> { storage.string("webJs") }
  public var sourceRegex: SourceField<String> { storage.string("sourceRegex") }
  public var replaceRegex: SourceField<String> { storage.string("replaceRegex") }
  public var imageStyle: SourceField<String> { storage.string("imageStyle") }
  public var imageDecode: SourceField<String> { storage.string("imageDecode") }
  public var payAction: SourceField<String> { storage.string("payAction") }

  public var jsonValue: JSONValue { storage.jsonValue }
  public var rawFields: [String: JSONValue] { storage.fields }
  public var unknownFields: [String: JSONValue] {
    storage.unknownFields(excluding: Self.knownFieldNames)
  }

  public func rawValue(for jsonName: String) -> JSONValue? {
    storage.rawValue(for: jsonName)
  }
}

public struct ReviewRuleDTO: LosslessSourceDocument {
  private static let knownFieldNames = Set(BookSourceSchema.reviewRuleFields.map(\.jsonName))
  private let storage: SourceObjectStorage

  public init(jsonValue: JSONValue) throws {
    self.storage = try SourceObjectStorage(jsonValue: jsonValue)
  }

  init(fields: [String: JSONValue]) {
    self.storage = SourceObjectStorage(fields: fields)
  }

  public var reviewUrl: SourceField<String> { storage.string("reviewUrl") }
  public var avatarRule: SourceField<String> { storage.string("avatarRule") }
  public var contentRule: SourceField<String> { storage.string("contentRule") }
  public var postTimeRule: SourceField<String> { storage.string("postTimeRule") }
  public var reviewQuoteUrl: SourceField<String> { storage.string("reviewQuoteUrl") }
  public var voteUpUrl: SourceField<String> { storage.string("voteUpUrl") }
  public var voteDownUrl: SourceField<String> { storage.string("voteDownUrl") }
  public var postReviewUrl: SourceField<String> { storage.string("postReviewUrl") }
  public var postQuoteUrl: SourceField<String> { storage.string("postQuoteUrl") }
  public var deleteUrl: SourceField<String> { storage.string("deleteUrl") }

  public var jsonValue: JSONValue { storage.jsonValue }
  public var rawFields: [String: JSONValue] { storage.fields }
  public var unknownFields: [String: JSONValue] {
    storage.unknownFields(excluding: Self.knownFieldNames)
  }

  public func rawValue(for jsonName: String) -> JSONValue? {
    storage.rawValue(for: jsonName)
  }
}
