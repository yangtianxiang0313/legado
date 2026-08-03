import AndroidBackupInterop
import AppUseCases
import Foundation
import LegadoCore
import LibraryDomain

public struct AndroidLibraryRestorePlan: Equatable, Sendable {
  public let books: [AndroidLibraryRestoreBook]
  public let groups: [AndroidLibraryRestoreGroup]
  public let bookmarks: [LibraryDomain.Bookmark]

  public init(
    books: [AndroidLibraryRestoreBook],
    groups: [AndroidLibraryRestoreGroup],
    bookmarks: [LibraryDomain.Bookmark]
  ) {
    self.books = books
    self.groups = groups
    self.bookmarks = bookmarks
  }
}

public struct AndroidLibraryRestoreBook: Equatable, Sendable {
  public let candidate: ShelfBookCandidate
  public let groupMask: Int64
  public let order: Int64
  public let chapterCount: Int
  public let progress: ReadingProgress
  public let latestChapterTime: Int64
  public let latestCheckCount: Int
  public let canUpdate: Bool
  public let reversesTableOfContents: Bool
  public let splitsLongChapters: Bool
  public let androidType: Int64
  public let originOrder: Int64
  public let syncTime: Int64
  public let charset: String?
  public let customTag: String?
  public let wordCount: String?

  public init(
    candidate: ShelfBookCandidate,
    groupMask: Int64,
    order: Int64,
    chapterCount: Int,
    progress: ReadingProgress,
    latestChapterTime: Int64,
    latestCheckCount: Int,
    canUpdate: Bool,
    reversesTableOfContents: Bool,
    splitsLongChapters: Bool,
    androidType: Int64,
    originOrder: Int64,
    syncTime: Int64,
    charset: String?,
    customTag: String?,
    wordCount: String?
  ) {
    self.candidate = candidate
    self.groupMask = groupMask
    self.order = order
    self.chapterCount = chapterCount
    self.progress = progress
    self.latestChapterTime = latestChapterTime
    self.latestCheckCount = latestCheckCount
    self.canUpdate = canUpdate
    self.reversesTableOfContents = reversesTableOfContents
    self.splitsLongChapters = splitsLongChapters
    self.androidType = androidType
    self.originOrder = originOrder
    self.syncTime = syncTime
    self.charset = charset
    self.customTag = customTag
    self.wordCount = wordCount
  }
}

public struct AndroidLibraryRestoreGroup: Equatable, Sendable {
  public let id: Int64
  public let name: String
  public let cover: String?
  public let order: Int
  public let enablesRefresh: Bool
  public let isShown: Bool
  public let bookSort: Int

  public init(
    id: Int64,
    name: String,
    cover: String?,
    order: Int,
    enablesRefresh: Bool,
    isShown: Bool,
    bookSort: Int
  ) {
    self.id = id
    self.name = name
    self.cover = cover
    self.order = order
    self.enablesRefresh = enablesRefresh
    self.isShown = isShown
    self.bookSort = bookSort
  }
}

public enum AndroidLibraryImportError: Error, Equatable, Sendable {
  case emptyBookURL(index: Int)
  case integerOutOfRange(field: String, value: Int64)
}

public enum AndroidLibraryImportAdapter {
  public static func plan(
    from archiveURL: URL
  ) throws -> AndroidLibraryRestorePlan {
    try plan(
      books: AndroidBackupArchive.readBooks(from: archiveURL),
      groups: AndroidBackupArchive.readBookGroups(from: archiveURL),
      bookmarks: AndroidBackupArchive.readBookmarks(from: archiveURL)
    )
  }

  public static func plan(
    books: [AndroidBookDTO],
    groups: [AndroidBookGroupDTO],
    bookmarks: [AndroidBookmarkDTO]
  ) throws -> AndroidLibraryRestorePlan {
    AndroidLibraryRestorePlan(
      books: try books.enumerated().map(mapBook),
      groups: try groups.map(mapGroup),
      bookmarks: bookmarks.map(mapBookmark)
    )
  }

  private static func mapBook(
    index: Int,
    document: AndroidBookDTO
  ) throws -> AndroidLibraryRestoreBook {
    let fields = document.rawFields
    let bookURL = fields.string("bookUrl") ?? ""
    guard !bookURL.isEmpty else {
      throw AndroidLibraryImportError.emptyBookURL(index: index)
    }
    let chapterCount = try platformInt(
      fields.integer("totalChapterNum") ?? 0,
      field: "totalChapterNum"
    )
    let chapterIndex = try platformInt(
      fields.integer("durChapterIndex") ?? 0,
      field: "durChapterIndex"
    )
    let chapterPosition = try platformInt(
      fields.integer("durChapterPos") ?? 0,
      field: "durChapterPos"
    )
    let latestCheckCount = try platformInt(
      fields.integer("lastCheckCount") ?? 0,
      field: "lastCheckCount"
    )
    let readConfig = fields.object("readConfig") ?? [:]
    return AndroidLibraryRestoreBook(
      candidate: ShelfBookCandidate(
        name: fields.string("name") ?? "",
        author: fields.string("author") ?? "",
        kind: fields.string("kind") ?? "",
        lastChapter: fields.string("latestChapterTitle") ?? "",
        intro: fields.string("intro") ?? "",
        bookURL: bookURL,
        tocURL: fields.nonEmptyString("tocUrl"),
        bookRequestExpression: bookURL,
        coverURL: fields.nonEmptyString("coverUrl"),
        customCoverURL: fields.nonEmptyString("customCoverUrl"),
        customIntro: fields.string("customIntro"),
        originName: fields.string("originName") ?? "",
        sourceID: fields.string("origin") ?? "",
        variables: decodeVariables(fields.string("variable"))
      ),
      groupMask: fields.integer("group") ?? 0,
      order: fields.integer("order") ?? 0,
      chapterCount: max(0, chapterCount),
      progress: ReadingProgress(
        position: ReadingPosition(
          chapterIndex: max(0, chapterIndex),
          characterOffset: max(0, chapterPosition)
        ),
        chapterTitle: fields.string("durChapterTitle"),
        updatedAtMilliseconds: fields.integer("durChapterTime") ?? 0
      ),
      latestChapterTime: fields.integer("latestChapterTime") ?? 0,
      latestCheckCount: max(0, latestCheckCount),
      canUpdate: fields.boolean("canUpdate") ?? true,
      reversesTableOfContents: readConfig.boolean("reverseToc") ?? false,
      splitsLongChapters: readConfig.boolean("splitLongChapter") ?? true,
      androidType: fields.integer("type") ?? 0,
      originOrder: fields.integer("originOrder") ?? 0,
      syncTime: fields.integer("syncTime") ?? 0,
      charset: fields.string("charset"),
      customTag: fields.string("customTag"),
      wordCount: fields.string("wordCount")
    )
  }

  private static func mapGroup(
    _ document: AndroidBookGroupDTO
  ) throws -> AndroidLibraryRestoreGroup {
    let fields = document.rawFields
    return AndroidLibraryRestoreGroup(
      id: fields.integer("groupId") ?? 0,
      name: fields.string("groupName") ?? "",
      cover: fields.string("cover"),
      order: try platformInt(
        fields.integer("order") ?? 0,
        field: "bookGroup.order"
      ),
      enablesRefresh: fields.boolean("enableRefresh") ?? true,
      isShown: fields.boolean("show") ?? true,
      bookSort: try platformInt(
        fields.integer("bookSort") ?? -1,
        field: "bookGroup.bookSort"
      )
    )
  }

  private static func mapBookmark(
    _ document: AndroidBookmarkDTO
  ) -> LibraryDomain.Bookmark {
    let fields = document.rawFields
    return LibraryDomain.Bookmark(
      time: fields.integer("time") ?? 0,
      bookName: fields.string("bookName") ?? "",
      bookAuthor: fields.string("bookAuthor") ?? "",
      chapterIndex: clampedPlatformInt(fields.integer("chapterIndex") ?? 0),
      chapterPosition: clampedPlatformInt(fields.integer("chapterPos") ?? 0),
      chapterName: fields.string("chapterName") ?? "",
      bookText: fields.string("bookText") ?? "",
      content: fields.string("content") ?? ""
    )
  }

  private static func platformInt(
    _ value: Int64,
    field: String
  ) throws -> Int {
    guard let result = Int(exactly: value) else {
      throw AndroidLibraryImportError.integerOutOfRange(
        field: field,
        value: value
      )
    }
    return result
  }

  private static func clampedPlatformInt(_ value: Int64) -> Int {
    if value > Int64(Int.max) { return Int.max }
    if value < Int64(Int.min) { return Int.min }
    return Int(value)
  }

  private static func decodeVariables(
    _ value: String?
  ) -> [String: String] {
    guard
      let value,
      let data = value.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data),
      let dictionary = object as? [String: Any]
    else {
      return [:]
    }
    return dictionary.reduce(into: [:]) { result, entry in
      if let string = entry.value as? String {
        result[entry.key] = string
      }
    }
  }
}

extension Dictionary where Key == String, Value == JSONValue {
  fileprivate func string(_ key: String) -> String? {
    guard case .string(let value) = self[key] else { return nil }
    return value
  }

  fileprivate func nonEmptyString(_ key: String) -> String? {
    guard let value = string(key), !value.isEmpty else { return nil }
    return value
  }

  fileprivate func integer(_ key: String) -> Int64? {
    guard case .number(let value) = self[key] else { return nil }
    return Int64(value.rawToken)
  }

  fileprivate func boolean(_ key: String) -> Bool? {
    guard case .bool(let value) = self[key] else { return nil }
    return value
  }

  fileprivate func object(_ key: String) -> [String: JSONValue]? {
    guard case .object(let value) = self[key] else { return nil }
    return value
  }
}
