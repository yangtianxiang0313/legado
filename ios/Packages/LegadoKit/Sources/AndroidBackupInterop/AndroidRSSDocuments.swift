import Foundation
import LegadoCore

public struct AndroidRSSSourceDTO: AndroidBackupJSONDocument {
  public static let knownFieldNames: Set<String> = [
    "sourceUrl", "sourceName", "sourceIcon", "sourceGroup", "sourceComment",
    "enabled", "variableComment", "jsLib", "enabledCookieJar", "concurrentRate",
    "header", "loginUrl", "loginUi", "loginCheckJs", "coverDecodeJs", "sortUrl",
    "singleUrl", "articleStyle", "ruleArticles", "ruleNextPage", "ruleTitle",
    "rulePubDate", "ruleDescription", "ruleImage", "ruleLink", "ruleContent",
    "contentWhitelist", "contentBlacklist", "shouldOverrideUrlLoading", "style",
    "enableJs", "loadWithBaseUrl", "injectJs", "lastUpdateTime", "customOrder",
  ]

  public let rawFields: [String: JSONValue]

  public init(jsonValue: JSONValue) throws {
    guard case .object(let fields) = jsonValue else {
      throw AndroidReplaceRuleFormatError.expectedObject
    }
    rawFields = fields
  }

  public init(
    values: [String: JSONValue?],
    unknownFields: [String: JSONValue] = [:]
  ) {
    rawFields = androidBackupFields(
      knownFieldNames: Self.knownFieldNames,
      unknownFields: unknownFields,
      values: values
    )
  }

  public func string(_ key: String) -> String? {
    guard case .string(let value) = rawFields[key] else { return nil }
    return value
  }

  public func integer(_ key: String) -> Int64? {
    guard case .number(let value) = rawFields[key] else { return nil }
    return Int64(value.rawToken)
  }

  public func boolean(_ key: String) -> Bool? {
    guard case .bool(let value) = rawFields[key] else { return nil }
    return value
  }
}

public struct AndroidRSSStarDTO: AndroidBackupJSONDocument {
  public static let knownFieldNames: Set<String> = [
    "origin", "sort", "title", "starTime", "link", "pubDate",
    "description", "content", "image", "variable",
  ]

  public let rawFields: [String: JSONValue]

  public init(jsonValue: JSONValue) throws {
    guard case .object(let fields) = jsonValue else {
      throw AndroidReplaceRuleFormatError.expectedObject
    }
    rawFields = fields
  }

  public init(
    values: [String: JSONValue?],
    unknownFields: [String: JSONValue] = [:]
  ) {
    rawFields = androidBackupFields(
      knownFieldNames: Self.knownFieldNames,
      unknownFields: unknownFields,
      values: values
    )
  }

  public func string(_ key: String) -> String? {
    guard case .string(let value) = rawFields[key] else { return nil }
    return value
  }

  public func integer(_ key: String) -> Int64? {
    guard case .number(let value) = rawFields[key] else { return nil }
    return Int64(value.rawToken)
  }
}

public enum AndroidRSSCodec {
  public static func decodeSources(
    _ data: Data,
    maximumDepth: Int = 128
  ) throws -> [AndroidRSSSourceDTO] {
    try AndroidBackupDocumentCodec.decodeMany(
      AndroidRSSSourceDTO.self,
      from: data,
      maximumDepth: maximumDepth
    )
  }

  public static func encodeSources(_ values: [AndroidRSSSourceDTO]) throws -> Data {
    try AndroidBackupDocumentCodec.encodeMany(values)
  }

  public static func decodeStars(
    _ data: Data,
    maximumDepth: Int = 128
  ) throws -> [AndroidRSSStarDTO] {
    try AndroidBackupDocumentCodec.decodeMany(
      AndroidRSSStarDTO.self,
      from: data,
      maximumDepth: maximumDepth
    )
  }

  public static func encodeStars(_ values: [AndroidRSSStarDTO]) throws -> Data {
    try AndroidBackupDocumentCodec.encodeMany(values)
  }
}
