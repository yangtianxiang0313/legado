import Foundation
import LegadoCore

public struct AndroidServerProfileDTO: AndroidBackupJSONDocument {
  public static let knownFieldNames: Set<String> = [
    "id", "name", "type", "config", "sortNumber",
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
    type: String = "WEBDAV",
    config: String?,
    sortNumber: Int,
    unknownFields: [String: JSONValue] = [:]
  ) {
    rawFields = androidBackupFields(
      knownFieldNames: Self.knownFieldNames,
      unknownFields: unknownFields,
      values: [
        "id": .number(JSONNumber(id)),
        "name": .string(name),
        "type": .string(type),
        "config": config.map(JSONValue.string),
        "sortNumber": .number(JSONNumber(Int64(sortNumber))),
      ]
    )
  }

  public var id: Int64 { integer("id") ?? 0 }
  public var name: String { string("name") ?? "" }
  public var type: String { string("type") ?? "WEBDAV" }
  public var config: String? { string("config") }
  public var sortNumber: Int { Int(integer("sortNumber") ?? 0) }

  private func string(_ key: String) -> String? {
    guard case .string(let value) = rawFields[key] else { return nil }
    return value
  }

  private func integer(_ key: String) -> Int64? {
    guard case .number(let value) = rawFields[key] else { return nil }
    return Int64(value.rawToken)
  }
}

public enum AndroidServerProfileCodecError: Error, Equatable, Sendable {
  case backupPasswordRequired
  case invalidBackupPassword
  case invalidPayloadEncoding
}

public enum AndroidServerProfileCodec {
  public static func decodePlaintext(
    _ data: Data,
    maximumDepth: Int = 128
  ) throws -> [AndroidServerProfileDTO] {
    try AndroidBackupDocumentCodec.decodeMany(
      AndroidServerProfileDTO.self,
      from: data,
      maximumDepth: maximumDepth
    )
  }

  public static func encodePlaintext(
    _ values: [AndroidServerProfileDTO]
  ) throws -> Data {
    try AndroidBackupDocumentCodec.encodeMany(values)
  }

  /// Mirrors Android Restore: accept a historical plaintext JSON array first,
  /// otherwise decrypt the entire Base64 text with BackupAES.
  public static func decodeArchivePayload(
    _ data: Data,
    backupPassword: String?,
    maximumDepth: Int = 128
  ) throws -> [AndroidServerProfileDTO] {
    if let values = try? decodePlaintext(data, maximumDepth: maximumDepth) {
      return values
    }
    guard let backupPassword, !backupPassword.isEmpty else {
      throw AndroidServerProfileCodecError.backupPasswordRequired
    }
    guard let payload = String(data: data, encoding: .utf8) else {
      throw AndroidServerProfileCodecError.invalidPayloadEncoding
    }
    do {
      let plaintext = try AndroidBackupAES.decryptBase64(
        payload,
        backupPassword: backupPassword
      )
      return try decodePlaintext(
        Data(plaintext.utf8),
        maximumDepth: maximumDepth
      )
    } catch {
      throw AndroidServerProfileCodecError.invalidBackupPassword
    }
  }

  public static func encodeArchivePayload(
    _ values: [AndroidServerProfileDTO],
    backupPassword: String
  ) throws -> Data {
    guard !backupPassword.isEmpty else {
      throw AndroidServerProfileCodecError.backupPasswordRequired
    }
    let plaintext = try encodePlaintext(values)
    guard let json = String(data: plaintext, encoding: .utf8) else {
      throw AndroidServerProfileCodecError.invalidPayloadEncoding
    }
    return Data(
      try AndroidBackupAES.encryptBase64(
        json,
        backupPassword: backupPassword
      ).utf8
    )
  }
}
