import Foundation
import LegadoCore

public struct AndroidDirectLinkUploadRuleDTO: AndroidBackupJSONDocument {
  public static let knownFieldNames: Set<String> = [
    "uploadUrl", "downloadUrlRule", "summary", "compress",
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
}

public enum AndroidDirectLinkUploadRuleCodec {
  public static func decode(
    _ data: Data,
    maximumDepth: Int = 128
  ) throws -> AndroidDirectLinkUploadRuleDTO {
    try AndroidDirectLinkUploadRuleDTO(
      jsonValue: JSONValueCodec.decode(data, maximumDepth: maximumDepth)
    )
  }

  public static func encode(
    _ value: AndroidDirectLinkUploadRuleDTO
  ) throws -> Data {
    try JSONValueCodec.encode(value.jsonValue)
  }
}
