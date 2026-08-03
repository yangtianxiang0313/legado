import Foundation
import LegadoCore

public struct AndroidReaderConfigDTO: AndroidBackupJSONDocument {
  public static let knownFieldNames: Set<String> = []
  public let rawFields: [String: JSONValue]

  public init(jsonValue: JSONValue) throws {
    guard case .object(let fields) = jsonValue else {
      throw AndroidReplaceRuleFormatError.expectedObject
    }
    rawFields = fields
  }

  public func integer(_ key: String) -> Int64? {
    guard case .number(let value) = rawFields[key] else { return nil }
    return Int64(value.rawToken)
  }
}

public enum AndroidReaderConfigCodec {
  public static func decodeList(
    _ data: Data,
    maximumDepth: Int = 128
  ) throws -> [AndroidReaderConfigDTO] {
    try AndroidBackupDocumentCodec.decodeMany(
      AndroidReaderConfigDTO.self,
      from: data,
      maximumDepth: maximumDepth
    )
  }

  public static func encodeList(_ values: [AndroidReaderConfigDTO]) throws
    -> Data
  {
    try AndroidBackupDocumentCodec.encodeMany(values)
  }

  public static func decodeShared(
    _ data: Data,
    maximumDepth: Int = 128
  ) throws -> AndroidReaderConfigDTO {
    try AndroidReaderConfigDTO(
      jsonValue: JSONValueCodec.decode(data, maximumDepth: maximumDepth)
    )
  }

  public static func encodeShared(_ value: AndroidReaderConfigDTO) throws
    -> Data
  {
    try JSONValueCodec.encode(value.jsonValue)
  }
}
