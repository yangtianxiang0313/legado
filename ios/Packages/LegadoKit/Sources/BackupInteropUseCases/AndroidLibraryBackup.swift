import AndroidBackupInterop
import Foundation
import LegadoCore
import LibraryDomain

public struct AndroidLibraryBackupSummary: Equatable, Sendable {
  public let bookCount: Int
  public let groupCount: Int
  public let bookmarkCount: Int

  public init(bookCount: Int, groupCount: Int, bookmarkCount: Int) {
    self.bookCount = bookCount
    self.groupCount = groupCount
    self.bookmarkCount = bookmarkCount
  }
}

public protocol AndroidLibraryBackupRepository: Sendable {
  func androidLibraryBackupPlan() async throws -> AndroidLibraryRestorePlan
}

public enum AndroidLibraryBackupError: Error, Equatable, Sendable {
  case integerOutOfRange(field: String, value: Int64)
}

public struct AndroidLibraryBackupUseCase: Sendable {
  private let repository: any AndroidLibraryBackupRepository

  public init(repository: any AndroidLibraryBackupRepository) {
    self.repository = repository
  }

  public func export(to archiveURL: URL) async throws
    -> AndroidLibraryBackupSummary
  {
    let plan = try await repository.androidLibraryBackupPlan()
    try AndroidBackupArchive.write(
      AndroidLibraryBackupAdapter.contents(from: plan),
      to: archiveURL
    )
    return AndroidLibraryBackupSummary(
      bookCount: plan.books.count,
      groupCount: plan.groups.count,
      bookmarkCount: plan.bookmarks.count
    )
  }
}

public enum AndroidLibraryBackupAdapter {
  public static func contents(from plan: AndroidLibraryRestorePlan) throws
    -> AndroidBackupContents
  {
    AndroidBackupContents(
      books: try plan.books.map(mapBook),
      bookGroups: try plan.groups.map(mapGroup),
      bookmarks: try plan.bookmarks.map(mapBookmark)
    )
  }

  private static func mapBook(_ value: AndroidLibraryRestoreBook) throws
    -> AndroidBookDTO
  {
    AndroidBookDTO(
      bookURL: value.candidate.bookURL,
      tocURL: value.candidate.tocURL ?? "",
      origin: value.candidate.sourceID,
      originName: value.candidate.originName,
      name: value.candidate.name,
      author: value.candidate.author,
      kind: value.candidate.kind,
      customTag: value.customTag,
      coverURL: value.candidate.coverURL,
      customCoverURL: value.candidate.customCoverURL,
      intro: value.candidate.intro,
      customIntro: value.candidate.customIntro,
      charset: value.charset,
      type: try int32(value.androidType, field: "type"),
      group: value.groupMask,
      latestChapterTitle: value.candidate.lastChapter,
      latestChapterTime: value.latestChapterTime,
      lastCheckTime: value.lastCheckTime,
      lastCheckCount: try int32(
        Int64(value.latestCheckCount), field: "lastCheckCount"
      ),
      totalChapterCount: try int32(
        Int64(value.chapterCount), field: "totalChapterNum"
      ),
      currentChapterTitle: value.progress.chapterTitle,
      currentChapterIndex: try int32(
        Int64(value.progress.position.chapterIndex), field: "durChapterIndex"
      ),
      currentChapterPosition: try int32(
        Int64(value.progress.position.characterOffset), field: "durChapterPos"
      ),
      lastReadTime: value.progress.updatedAtMilliseconds,
      wordCount: value.wordCount,
      canUpdate: value.canUpdate,
      order: try int32(value.order, field: "order"),
      originOrder: try int32(value.originOrder, field: "originOrder"),
      variable: try encodedVariables(value.candidate.variables),
      readConfig: [
        "reverseToc": .bool(value.reversesTableOfContents),
        "splitLongChapter": .bool(value.splitsLongChapters),
      ],
      syncTime: value.syncTime
    )
  }

  private static func mapGroup(_ value: AndroidLibraryRestoreGroup) throws
    -> AndroidBookGroupDTO
  {
    AndroidBookGroupDTO(
      groupID: value.id,
      groupName: value.name,
      cover: value.cover,
      order: try int32(Int64(value.order), field: "bookGroup.order"),
      enableRefresh: value.enablesRefresh,
      show: value.isShown,
      bookSort: try int32(Int64(value.bookSort), field: "bookGroup.bookSort")
    )
  }

  private static func mapBookmark(_ value: Bookmark) throws
    -> AndroidBookmarkDTO
  {
    AndroidBookmarkDTO(
      time: value.time,
      bookName: value.bookName,
      bookAuthor: value.bookAuthor,
      chapterIndex: try int32(
        Int64(value.chapterIndex), field: "bookmark.chapterIndex"
      ),
      chapterPosition: try int32(
        Int64(value.chapterPosition), field: "bookmark.chapterPos"
      ),
      chapterName: value.chapterName,
      bookText: value.bookText,
      content: value.content
    )
  }

  private static func int32(_ value: Int64, field: String) throws -> Int32 {
    guard let result = Int32(exactly: value) else {
      throw AndroidLibraryBackupError.integerOutOfRange(
        field: field,
        value: value
      )
    }
    return result
  }

  private static func encodedVariables(_ variables: [String: String]) throws
    -> String?
  {
    guard !variables.isEmpty else { return nil }
    let data = try JSONSerialization.data(
      withJSONObject: variables,
      options: [.sortedKeys]
    )
    return String(decoding: data, as: UTF8.self)
  }
}
