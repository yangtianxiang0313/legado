import Foundation
import LegadoCore
import SourceFormat

public struct AndroidBookDTO: AndroidBackupJSONDocument {
  public static let knownFieldNames: Set<String> = [
    "bookUrl", "tocUrl", "origin", "originName", "name", "author",
    "kind", "customTag", "coverUrl", "customCoverUrl", "intro",
    "customIntro", "charset", "type", "group", "latestChapterTitle",
    "latestChapterTime", "lastCheckTime", "lastCheckCount",
    "totalChapterNum", "durChapterTitle", "durChapterIndex",
    "durChapterPos", "durChapterTime", "wordCount", "canUpdate",
    "order", "originOrder", "variable", "readConfig", "syncTime",
  ]

  public let rawFields: [String: JSONValue]

  public init(jsonValue: JSONValue) throws {
    guard case .object(let fields) = jsonValue else {
      throw AndroidReplaceRuleFormatError.expectedObject
    }
    rawFields = fields
  }

  public init(
    bookURL: String,
    tocURL: String = "",
    origin: String,
    originName: String,
    name: String,
    author: String,
    kind: String? = nil,
    customTag: String? = nil,
    coverURL: String? = nil,
    customCoverURL: String? = nil,
    intro: String? = nil,
    customIntro: String? = nil,
    charset: String? = nil,
    type: Int32 = 0,
    group: Int64 = 0,
    latestChapterTitle: String? = nil,
    latestChapterTime: Int64 = 0,
    lastCheckTime: Int64 = 0,
    lastCheckCount: Int32 = 0,
    totalChapterCount: Int32 = 0,
    currentChapterTitle: String? = nil,
    currentChapterIndex: Int32 = 0,
    currentChapterPosition: Int32 = 0,
    lastReadTime: Int64 = 0,
    wordCount: String? = nil,
    canUpdate: Bool = true,
    order: Int32 = 0,
    originOrder: Int32 = 0,
    variable: String? = nil,
    readConfig: [String: JSONValue]? = nil,
    syncTime: Int64 = 0,
    unknownFields: [String: JSONValue] = [:]
  ) {
    rawFields = androidBackupFields(
      knownFieldNames: Self.knownFieldNames,
      unknownFields: unknownFields,
      values: [
        "bookUrl": .string(bookURL),
        "tocUrl": .string(tocURL),
        "origin": .string(origin),
        "originName": .string(originName),
        "name": .string(name),
        "author": .string(author),
        "kind": kind.map(JSONValue.string),
        "customTag": customTag.map(JSONValue.string),
        "coverUrl": coverURL.map(JSONValue.string),
        "customCoverUrl": customCoverURL.map(JSONValue.string),
        "intro": intro.map(JSONValue.string),
        "customIntro": customIntro.map(JSONValue.string),
        "charset": charset.map(JSONValue.string),
        "type": .number(JSONNumber(Int64(type))),
        "group": .number(JSONNumber(group)),
        "latestChapterTitle": latestChapterTitle.map(JSONValue.string),
        "latestChapterTime": .number(JSONNumber(latestChapterTime)),
        "lastCheckTime": .number(JSONNumber(lastCheckTime)),
        "lastCheckCount": .number(JSONNumber(Int64(lastCheckCount))),
        "totalChapterNum": .number(JSONNumber(Int64(totalChapterCount))),
        "durChapterTitle": currentChapterTitle.map(JSONValue.string),
        "durChapterIndex": .number(JSONNumber(Int64(currentChapterIndex))),
        "durChapterPos": .number(JSONNumber(Int64(currentChapterPosition))),
        "durChapterTime": .number(JSONNumber(lastReadTime)),
        "wordCount": wordCount.map(JSONValue.string),
        "canUpdate": .bool(canUpdate),
        "order": .number(JSONNumber(Int64(order))),
        "originOrder": .number(JSONNumber(Int64(originOrder))),
        "variable": variable.map(JSONValue.string),
        "readConfig": readConfig.map(JSONValue.object),
        "syncTime": .number(JSONNumber(syncTime)),
      ]
    )
  }

  public var bookURL: SourceField<String> { backupString("bookUrl") }
  public var name: SourceField<String> { backupString("name") }
  public var author: SourceField<String> { backupString("author") }
  public var group: SourceField<Int64> { backupInteger("group") }
  public var currentChapterIndex: SourceField<Int64> {
    backupInteger("durChapterIndex")
  }
  public var currentChapterPosition: SourceField<Int64> {
    backupInteger("durChapterPos")
  }
  public var readConfig: SourceField<[String: JSONValue]> {
    backupObject("readConfig")
  }
}

public struct AndroidBookGroupDTO: AndroidBackupJSONDocument {
  public static let knownFieldNames: Set<String> = [
    "groupId", "groupName", "cover", "order", "enableRefresh", "show",
    "bookSort",
  ]
  public let rawFields: [String: JSONValue]

  public init(jsonValue: JSONValue) throws {
    guard case .object(let fields) = jsonValue else {
      throw AndroidReplaceRuleFormatError.expectedObject
    }
    rawFields = fields
  }

  public init(
    groupID: Int64,
    groupName: String,
    cover: String? = nil,
    order: Int32 = 0,
    enableRefresh: Bool = true,
    show: Bool = true,
    bookSort: Int32 = -1,
    unknownFields: [String: JSONValue] = [:]
  ) {
    rawFields = androidBackupFields(
      knownFieldNames: Self.knownFieldNames,
      unknownFields: unknownFields,
      values: [
        "groupId": .number(JSONNumber(groupID)),
        "groupName": .string(groupName),
        "cover": cover.map(JSONValue.string),
        "order": .number(JSONNumber(Int64(order))),
        "enableRefresh": .bool(enableRefresh),
        "show": .bool(show),
        "bookSort": .number(JSONNumber(Int64(bookSort))),
      ]
    )
  }

  public var groupID: SourceField<Int64> { backupInteger("groupId") }
  public var groupName: SourceField<String> { backupString("groupName") }
}

public struct AndroidBookmarkDTO: AndroidBackupJSONDocument {
  public static let knownFieldNames: Set<String> = [
    "time", "bookName", "bookAuthor", "chapterIndex", "chapterPos",
    "chapterName", "bookText", "content",
  ]
  public let rawFields: [String: JSONValue]

  public init(jsonValue: JSONValue) throws {
    guard case .object(let fields) = jsonValue else {
      throw AndroidReplaceRuleFormatError.expectedObject
    }
    rawFields = fields
  }

  public init(
    time: Int64,
    bookName: String,
    bookAuthor: String,
    chapterIndex: Int32,
    chapterPosition: Int32,
    chapterName: String,
    bookText: String,
    content: String,
    unknownFields: [String: JSONValue] = [:]
  ) {
    rawFields = androidBackupFields(
      knownFieldNames: Self.knownFieldNames,
      unknownFields: unknownFields,
      values: [
        "time": .number(JSONNumber(time)),
        "bookName": .string(bookName),
        "bookAuthor": .string(bookAuthor),
        "chapterIndex": .number(JSONNumber(Int64(chapterIndex))),
        "chapterPos": .number(JSONNumber(Int64(chapterPosition))),
        "chapterName": .string(chapterName),
        "bookText": .string(bookText),
        "content": .string(content),
      ]
    )
  }

  public var time: SourceField<Int64> { backupInteger("time") }
  public var bookName: SourceField<String> { backupString("bookName") }
  public var chapterIndex: SourceField<Int64> { backupInteger("chapterIndex") }
  public var chapterPosition: SourceField<Int64> { backupInteger("chapterPos") }
}

public enum AndroidBookCodec {
  public static func decodeMany(_ data: Data, maximumDepth: Int = 128) throws
    -> [AndroidBookDTO]
  {
    try AndroidBackupDocumentCodec.decodeMany(
      AndroidBookDTO.self, from: data, maximumDepth: maximumDepth
    )
  }
  public static func encodeMany(_ values: [AndroidBookDTO]) throws -> Data {
    try AndroidBackupDocumentCodec.encodeMany(values)
  }
}

public enum AndroidBookGroupCodec {
  public static func decodeMany(_ data: Data, maximumDepth: Int = 128) throws
    -> [AndroidBookGroupDTO]
  {
    try AndroidBackupDocumentCodec.decodeMany(
      AndroidBookGroupDTO.self, from: data, maximumDepth: maximumDepth
    )
  }
  public static func encodeMany(_ values: [AndroidBookGroupDTO]) throws -> Data {
    try AndroidBackupDocumentCodec.encodeMany(values)
  }
}

public enum AndroidBookmarkCodec {
  public static func decodeMany(_ data: Data, maximumDepth: Int = 128) throws
    -> [AndroidBookmarkDTO]
  {
    try AndroidBackupDocumentCodec.decodeMany(
      AndroidBookmarkDTO.self, from: data, maximumDepth: maximumDepth
    )
  }
  public static func encodeMany(_ values: [AndroidBookmarkDTO]) throws -> Data {
    try AndroidBackupDocumentCodec.encodeMany(values)
  }
}
