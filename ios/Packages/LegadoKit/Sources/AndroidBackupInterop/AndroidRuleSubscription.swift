import Foundation
import LegadoCore

public struct AndroidRuleSubscriptionDTO: AndroidBackupJSONDocument {
  public static let knownFieldNames: Set<String> = [
    "id", "name", "url", "type", "customOrder", "autoUpdate", "update",
  ]

  public let rawFields: [String: JSONValue]

  public init(jsonValue: JSONValue) throws {
    guard case .object(let fields) = jsonValue else {
      throw AndroidReplaceRuleFormatError.expectedObject
    }
    rawFields = fields
  }

  public init(
    id: Int64,
    name: String,
    url: String,
    type: Int,
    customOrder: Int,
    autoUpdate: Bool,
    updatedAt: Int64,
    unknownFields: [String: JSONValue] = [:]
  ) {
    rawFields = androidBackupFields(
      knownFieldNames: Self.knownFieldNames,
      unknownFields: unknownFields,
      values: [
        "id": .number(JSONNumber(id)),
        "name": .string(name),
        "url": .string(url),
        "type": .number(JSONNumber(Int64(type))),
        "customOrder": .number(JSONNumber(Int64(customOrder))),
        "autoUpdate": .bool(autoUpdate),
        "update": .number(JSONNumber(updatedAt)),
      ]
    )
  }

  public var id: Int64 { integer("id") ?? 0 }
  public var name: String { string("name") ?? "" }
  public var url: String { string("url") ?? "" }
  public var type: Int { Int(integer("type") ?? 0) }
  public var customOrder: Int { Int(integer("customOrder") ?? 0) }
  public var autoUpdate: Bool {
    guard case .bool(let value) = rawFields["autoUpdate"] else { return false }
    return value
  }
  public var updatedAt: Int64 { integer("update") ?? 0 }

  private func string(_ key: String) -> String? {
    guard case .string(let value) = rawFields[key] else { return nil }
    return value
  }

  private func integer(_ key: String) -> Int64? {
    guard case .number(let value) = rawFields[key] else { return nil }
    return Int64(value.rawToken)
  }
}

public enum AndroidRuleSubscriptionCodec {
  public static func decodeMany(
    _ data: Data,
    maximumDepth: Int = 128
  ) throws -> [AndroidRuleSubscriptionDTO] {
    try AndroidBackupDocumentCodec.decodeMany(
      AndroidRuleSubscriptionDTO.self,
      from: data,
      maximumDepth: maximumDepth
    )
  }

  public static func encodeMany(_ values: [AndroidRuleSubscriptionDTO]) throws -> Data {
    try AndroidBackupDocumentCodec.encodeMany(values)
  }
}
