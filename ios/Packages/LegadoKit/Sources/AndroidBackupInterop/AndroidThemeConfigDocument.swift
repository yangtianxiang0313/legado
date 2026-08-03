import Foundation
import LegadoCore

public struct AndroidThemeConfigDTO: AndroidBackupJSONDocument {
  public static let knownFieldNames: Set<String> = [
    "themeName", "isNightTheme", "primaryColor", "accentColor",
    "backgroundColor", "bottomBackground",
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

  public func boolean(_ key: String) -> Bool? {
    guard case .bool(let value) = rawFields[key] else { return nil }
    return value
  }
}

public enum AndroidThemeConfigCodec {
  public static func decodeMany(_ data: Data, maximumDepth: Int = 128) throws
    -> [AndroidThemeConfigDTO]
  {
    try AndroidBackupDocumentCodec.decodeMany(
      AndroidThemeConfigDTO.self,
      from: data,
      maximumDepth: maximumDepth
    )
  }

  public static func encodeMany(_ values: [AndroidThemeConfigDTO]) throws -> Data {
    try AndroidBackupDocumentCodec.encodeMany(values)
  }
}
