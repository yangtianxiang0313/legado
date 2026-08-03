import Foundation
import LegadoCore

public struct AndroidLocalTextTOCRuleDTO: AndroidBackupJSONDocument {
  public static let knownFieldNames: Set<String> = [
    "id", "name", "rule", "example", "serialNumber", "enable",
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

public enum AndroidLocalTextTOCRuleCodec {
  public static func decodeMany(
    _ data: Data,
    maximumDepth: Int = 128
  ) throws -> [AndroidLocalTextTOCRuleDTO] {
    try AndroidBackupDocumentCodec.decodeMany(
      AndroidLocalTextTOCRuleDTO.self,
      from: data,
      maximumDepth: maximumDepth
    )
  }

  public static func encodeMany(
    _ values: [AndroidLocalTextTOCRuleDTO]
  ) throws -> Data {
    try AndroidBackupDocumentCodec.encodeMany(values)
  }
}
