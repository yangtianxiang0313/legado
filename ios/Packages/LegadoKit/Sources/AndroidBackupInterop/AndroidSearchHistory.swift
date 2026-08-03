import Foundation
import LegadoCore

public struct AndroidSearchHistoryDTO: AndroidBackupJSONDocument {
  public static let knownFieldNames: Set<String> = [
    "word", "usage", "lastUseTime",
  ]

  public let rawFields: [String: JSONValue]

  public init(jsonValue: JSONValue) throws {
    guard case .object(let fields) = jsonValue else {
      throw AndroidReplaceRuleFormatError.expectedObject
    }
    rawFields = fields
  }

  public init(
    word: String,
    usage: Int,
    lastUseTime: Int64,
    unknownFields: [String: JSONValue] = [:]
  ) {
    rawFields = androidBackupFields(
      knownFieldNames: Self.knownFieldNames,
      unknownFields: unknownFields,
      values: [
        "word": .string(word),
        "usage": .number(JSONNumber(Int64(usage))),
        "lastUseTime": .number(JSONNumber(lastUseTime)),
      ]
    )
  }

  public var word: String {
    guard case .string(let value) = rawFields["word"] else { return "" }
    return value
  }

  public var usage: Int {
    guard case .number(let value) = rawFields["usage"] else { return 1 }
    return Int(value.rawToken) ?? 1
  }

  public var lastUseTime: Int64 {
    guard case .number(let value) = rawFields["lastUseTime"] else { return 0 }
    return Int64(value.rawToken) ?? 0
  }
}

public enum AndroidSearchHistoryCodec {
  public static func decodeMany(
    _ data: Data,
    maximumDepth: Int = 128
  ) throws -> [AndroidSearchHistoryDTO] {
    try AndroidBackupDocumentCodec.decodeMany(
      AndroidSearchHistoryDTO.self,
      from: data,
      maximumDepth: maximumDepth
    )
  }

  public static func encodeMany(_ values: [AndroidSearchHistoryDTO]) throws -> Data {
    try AndroidBackupDocumentCodec.encodeMany(values)
  }
}
