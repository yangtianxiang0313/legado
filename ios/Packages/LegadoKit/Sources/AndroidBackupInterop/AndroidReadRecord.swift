import Foundation
import LegadoCore

public struct AndroidReadRecordDTO: AndroidBackupJSONDocument {
  public static let knownFieldNames: Set<String> = [
    "deviceId", "bookName", "readTime", "lastRead",
  ]

  public let rawFields: [String: JSONValue]

  public init(jsonValue: JSONValue) throws {
    guard case .object(let fields) = jsonValue else {
      throw AndroidReplaceRuleFormatError.expectedObject
    }
    rawFields = fields
  }

  public init(
    deviceID: String,
    bookName: String,
    readTime: Int64,
    lastRead: Int64,
    unknownFields: [String: JSONValue] = [:]
  ) {
    rawFields = androidBackupFields(
      knownFieldNames: Self.knownFieldNames,
      unknownFields: unknownFields,
      values: [
        "deviceId": .string(deviceID),
        "bookName": .string(bookName),
        "readTime": .number(JSONNumber(readTime)),
        "lastRead": .number(JSONNumber(lastRead)),
      ]
    )
  }

  public var restoreProjection: AndroidReadRecordRestoreProjection {
    AndroidReadRecordRestoreProjection(
      deviceID: string("deviceId") ?? "",
      bookName: string("bookName") ?? "",
      readTime: integer("readTime") ?? 0,
      lastRead: integer("lastRead") ?? 0
    )
  }

  private func string(_ name: String) -> String? {
    guard case .string(let value) = rawFields[name] else { return nil }
    return value
  }

  private func integer(_ name: String) -> Int64? {
    guard case .number(let value) = rawFields[name] else { return nil }
    return Int64(value.rawToken)
  }
}

public struct AndroidReadRecordRestoreProjection: Equatable, Sendable {
  public let deviceID: String
  public let bookName: String
  public let readTime: Int64
  public let lastRead: Int64
}

public enum AndroidReadRecordCodec {
  public static func decodeMany(
    _ data: Data,
    maximumDepth: Int = 128
  ) throws -> [AndroidReadRecordDTO] {
    try AndroidBackupDocumentCodec.decodeMany(
      AndroidReadRecordDTO.self,
      from: data,
      maximumDepth: maximumDepth
    )
  }

  public static func encodeMany(_ values: [AndroidReadRecordDTO]) throws
    -> Data
  {
    try AndroidBackupDocumentCodec.encodeMany(values)
  }
}
