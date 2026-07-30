import Foundation
import LegadoCore

public enum BookSourceEditorCodecError:
  Error,
  Equatable,
  Sendable
{
  case invalidRuleObject(String)
}

public struct BookSourceEditableDefinition:
  Equatable,
  Sendable
{
  public var sourceURL: String
  public var name: String
  public var group: String
  public var comment: String
  public var loginURL: String
  public var searchURL: String
  public var exploreURL: String
  public var searchRule: String
  public var exploreRule: String
  public var bookInfoRule: String
  public var tocRule: String
  public var contentRule: String
  public var enabled: Bool
  public var enabledExplore: Bool
  public var lastUpdateTime: Int64
  public var customOrder: Int32

  public init(
    sourceURL: String = "",
    name: String = "",
    group: String = "",
    comment: String = "",
    loginURL: String = "",
    searchURL: String = "",
    exploreURL: String = "",
    searchRule: String = "",
    exploreRule: String = "",
    bookInfoRule: String = "",
    tocRule: String = "",
    contentRule: String = "",
    enabled: Bool = true,
    enabledExplore: Bool = true,
    lastUpdateTime: Int64 = 0,
    customOrder: Int32 = 0
  ) {
    self.sourceURL = sourceURL
    self.name = name
    self.group = group
    self.comment = comment
    self.loginURL = loginURL
    self.searchURL = searchURL
    self.exploreURL = exploreURL
    self.searchRule = searchRule
    self.exploreRule = exploreRule
    self.bookInfoRule = bookInfoRule
    self.tocRule = tocRule
    self.contentRule = contentRule
    self.enabled = enabled
    self.enabledExplore = enabledExplore
    self.lastUpdateTime = lastUpdateTime
    self.customOrder = customOrder
  }
}

public enum BookSourceEditorCodec {
  public static func project(
    _ data: Data
  ) throws -> BookSourceEditableDefinition {
    try project(BookSourceCodec.decode(data))
  }

  public static func project(
    _ source: BookSourceDTO
  ) throws -> BookSourceEditableDefinition {
    BookSourceEditableDefinition(
      sourceURL: string(source.bookSourceUrl),
      name: string(source.bookSourceName),
      group: string(source.bookSourceGroup),
      comment: string(source.bookSourceComment),
      loginURL: string(source.loginUrl),
      searchURL: string(source.searchUrl),
      exploreURL: string(source.exploreUrl),
      searchRule: try ruleJSON(
        source.rawValue(for: "ruleSearch")
      ),
      exploreRule: try ruleJSON(
        source.rawValue(for: "ruleExplore")
      ),
      bookInfoRule: try ruleJSON(
        source.rawValue(for: "ruleBookInfo")
      ),
      tocRule: try ruleJSON(
        source.rawValue(for: "ruleToc")
      ),
      contentRule: try ruleJSON(
        source.rawValue(for: "ruleContent")
      ),
      enabled: boolean(source.enabled, fallback: true),
      enabledExplore: boolean(
        source.enabledExplore,
        fallback: true
      ),
      lastUpdateTime: int64(source.lastUpdateTime),
      customOrder: int32(source.customOrder)
    )
  }

  public static func applying(
    _ edit: BookSourceEditableDefinition,
    to original: Data?
  ) throws -> Data {
    let root: [String: JSONValue]
    if let original {
      let value = try JSONValueCodec.decode(original)
      guard case .object(let object) = value else {
        throw SourceFormatError.expectedObject
      }
      root = object
    } else {
      root = [:]
    }
    var result = root
    result["bookSourceUrl"] = .string(edit.sourceURL)
    result["bookSourceName"] = .string(edit.name)
    result["bookSourceGroup"] = .string(edit.group)
    result["bookSourceComment"] = .string(edit.comment)
    result["loginUrl"] = .string(edit.loginURL)
    result["searchUrl"] = .string(edit.searchURL)
    result["exploreUrl"] = .string(edit.exploreURL)
    result["enabled"] = .bool(edit.enabled)
    result["enabledExplore"] = .bool(edit.enabledExplore)
    result["lastUpdateTime"] = .number(
      try JSONNumber(
        validating: String(edit.lastUpdateTime)
      )
    )
    result["customOrder"] = .number(
      try JSONNumber(
        validating: String(edit.customOrder)
      )
    )
    try replaceRule(
      "ruleSearch",
      text: edit.searchRule,
      in: &result
    )
    try replaceRule(
      "ruleExplore",
      text: edit.exploreRule,
      in: &result
    )
    try replaceRule(
      "ruleBookInfo",
      text: edit.bookInfoRule,
      in: &result
    )
    try replaceRule(
      "ruleToc",
      text: edit.tocRule,
      in: &result
    )
    try replaceRule(
      "ruleContent",
      text: edit.contentRule,
      in: &result
    )
    return try JSONValueCodec.encode(.object(result))
  }

  private static func replaceRule(
    _ key: String,
    text: String,
    in root: inout [String: JSONValue]
  ) throws {
    let normalized = text.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    guard !normalized.isEmpty else {
      root.removeValue(forKey: key)
      return
    }
    let value = try JSONValueCodec.decode(
      Data(normalized.utf8)
    )
    guard case .object = value else {
      throw BookSourceEditorCodecError
        .invalidRuleObject(key)
    }
    root[key] = value
  }

  private static func ruleJSON(
    _ value: JSONValue?
  ) throws -> String {
    guard let value, case .object = value else {
      return ""
    }
    return String(
      decoding: try JSONValueCodec.encode(value),
      as: UTF8.self
    )
  }

  private static func string(
    _ field: SourceField<String>
  ) -> String {
    guard case .value(let value) = field else {
      return ""
    }
    return value
  }

  private static func boolean(
    _ field: SourceField<Bool>,
    fallback: Bool
  ) -> Bool {
    guard case .value(let value) = field else {
      return fallback
    }
    return value
  }

  private static func int64(
    _ field: SourceField<Int64>
  ) -> Int64 {
    guard case .value(let value) = field else {
      return 0
    }
    return value
  }

  private static func int32(
    _ field: SourceField<Int32>
  ) -> Int32 {
    guard case .value(let value) = field else {
      return 0
    }
    return value
  }
}
