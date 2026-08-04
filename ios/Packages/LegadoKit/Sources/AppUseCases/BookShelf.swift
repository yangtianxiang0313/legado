import Foundation
import IntegrationKit
import LibraryDomain
import Observation
import ReaderCore

public struct ShelfBookCandidate: Equatable, Sendable {
  public let name: String
  public let author: String
  public let kind: String
  public let lastChapter: String
  public let intro: String
  public let bookURL: String
  public let tocURL: String?
  public let bookRequestExpression: String
  public let coverURL: String?
  public let customCoverURL: String?
  public let customIntro: String?
  public let originName: String
  public let sourceID: String
  public let variables: [String: String]

  public init(
    name: String,
    author: String,
    kind: String,
    lastChapter: String,
    intro: String,
    bookURL: String,
    tocURL: String? = nil,
    bookRequestExpression: String? = nil,
    coverURL: String?,
    customCoverURL: String? = nil,
    customIntro: String? = nil,
    originName: String,
    sourceID: String = "",
    variables: [String: String] = [:]
  ) {
    self.name = name
    self.author = author
    self.kind = kind
    self.lastChapter = lastChapter
    self.intro = intro
    self.bookURL = bookURL
    self.tocURL = tocURL
    self.bookRequestExpression = bookRequestExpression ?? bookURL
    self.coverURL = coverURL
    self.customCoverURL = customCoverURL
    self.customIntro = customIntro
    self.originName = originName
    self.sourceID = sourceID
    self.variables = variables
  }

  public var displayCoverURL: String? {
    guard let customCoverURL, !customCoverURL.isEmpty else {
      return coverURL
    }
    return customCoverURL
  }

  public var displayIntro: String {
    guard let customIntro, !customIntro.isEmpty else {
      return intro
    }
    return customIntro
  }
}

public enum AndroidWebDAVBookOrigin {
  public static let prefix = "webDav::"

  public struct Value: Sendable, Equatable {
    public let remoteURL: URL
    public let serverID: Int64

    public init(remoteURL: URL, serverID: Int64) {
      self.remoteURL = remoteURL
      self.serverID = serverID
    }
  }

  public static func encode(
    remoteURL: URL,
    serverID: Int64
  ) -> String {
    let attributes = "{\"serverID\":\(serverID)}"
    return prefix + remoteURL.absoluteString + "," + attributes
  }

  public static func decode(_ sourceID: String) -> Value? {
    guard sourceID.hasPrefix(prefix) else { return nil }
    let payload = String(sourceID.dropFirst(prefix.count))
    guard
      let delimiter = payload.range(of: ",{", options: .backwards),
      let remoteURL = URL(
        string: String(payload[..<delimiter.lowerBound])
      ),
      let data = String(payload[delimiter.upperBound...]).data(using: .utf8),
      let decoded = try? JSONSerialization.jsonObject(
        with: Data("{".utf8) + data
      ),
      let object = decoded as? [String: Any],
      let number = object["serverID"] as? NSNumber
    else {
      return nil
    }
    return Value(remoteURL: remoteURL, serverID: number.int64Value)
  }

  public static func isLocalSource(_ sourceID: String) -> Bool {
    sourceID == "local-file"
      || sourceID == "loc_book"
      || AndroidLocalArchiveBookOrigin.decode(sourceID) != nil
      || sourceID.hasPrefix(prefix)
  }

  public static func applying(
    to candidate: ShelfBookCandidate,
    remoteURL: URL,
    serverID: Int64
  ) -> ShelfBookCandidate {
    ShelfBookCandidate(
      name: candidate.name,
      author: candidate.author,
      kind: candidate.kind,
      lastChapter: candidate.lastChapter,
      intro: candidate.intro,
      bookURL: candidate.bookURL,
      tocURL: candidate.tocURL,
      bookRequestExpression: candidate.bookRequestExpression,
      coverURL: candidate.coverURL,
      customCoverURL: candidate.customCoverURL,
      customIntro: candidate.customIntro,
      originName: candidate.originName,
      sourceID: encode(remoteURL: remoteURL, serverID: serverID),
      variables: candidate.variables
    )
  }
}

public struct BookMetadataUpdate: Equatable, Sendable {
  public let name: String
  public let author: String
  public let coverURL: String
  public let intro: String

  public init(
    name: String,
    author: String,
    coverURL: String,
    intro: String
  ) {
    self.name = name
    self.author = author
    self.coverURL = coverURL
    self.intro = intro
  }
}

public struct ShelfBookItem: Identifiable, Equatable, Sendable {
  public let id: LibraryDomain.BookID
  public let candidate: ShelfBookCandidate
  public let membership: ShelfMembership
  public let order: Int64
  public let chapterCount: Int
  public let progress: ReadingProgress?
  public let latestChapterTime: Int64
  public let lastCheckTime: Int64
  public let latestCheckCount: Int
  public let canUpdate: Bool
  public let reversesTableOfContents: Bool
  public let splitsLongChapters: Bool
  public let usesReplacementRules: Bool
  public let ttsEngine: String?
  public let imageStyle: String?

  public init(
    id: LibraryDomain.BookID,
    candidate: ShelfBookCandidate,
    membership: ShelfMembership,
    order: Int64,
    chapterCount: Int,
    progress: ReadingProgress? = nil,
    latestChapterTime: Int64 = 0,
    lastCheckTime: Int64 = 0,
    latestCheckCount: Int = 0,
    canUpdate: Bool = true,
    reversesTableOfContents: Bool = false,
    splitsLongChapters: Bool = true,
    usesReplacementRules: Bool = true,
    ttsEngine: String? = nil,
    imageStyle: String? = nil
  ) {
    self.id = id
    self.candidate = candidate
    self.membership = membership
    self.order = order
    self.chapterCount = chapterCount
    self.progress = progress
    self.latestChapterTime = latestChapterTime
    self.lastCheckTime = max(0, lastCheckTime)
    self.latestCheckCount = max(0, latestCheckCount)
    self.canUpdate = canUpdate
    self.reversesTableOfContents = reversesTableOfContents
    self.splitsLongChapters = splitsLongChapters
    self.usesReplacementRules = usesReplacementRules
    self.ttsEngine = ttsEngine
    self.imageStyle = imageStyle
  }

  public var unreadChapterCount: Int {
    max(chapterCount - (progress?.position.chapterIndex ?? 0) - 1, 0)
  }

  public var lastReadTime: Int64 {
    progress?.updatedAtMilliseconds ?? 0
  }

  public var presentation: ShelfPresentationBook {
    ShelfPresentationBook(
      id: id,
      name: candidate.name,
      manualOrder: order,
      latestChapterTime: latestChapterTime,
      lastReadTime: lastReadTime
    )
  }
}

public struct ShelfGroupItem: Identifiable, Equatable, Sendable {
  public let id: Int
  public let name: String
  public let order: Int
  public let isShown: Bool

  public init(
    id: Int,
    name: String,
    order: Int = 0,
    isShown: Bool = true
  ) {
    self.id = id
    self.name = name
    self.order = order
    self.isShown = isShown
  }
}

public enum ShelfBatchMutation: Equatable, Sendable {
  case delete
  case clearCache
  case setCanUpdate(Bool)
  case moveToGroup(Int)
}

public enum ShelfMutationFailure: Error, Equatable, Sendable {
  case missingBook
}

public enum BookImportFailure: Error, Equatable, Sendable {
  case unsupportedRepository
  case unsupportedFileType
  case emptyFile
  case unreadableText
}

public enum ReaderContentRefreshScope: Equatable, Sendable {
  case current
  case currentAndAfter
  case all
}

public protocol BookShelfRepository:
  Sendable, ReaderReplacementRuleRepository, ReadRecordStore,
  LocalTextTOCRuleRepository, WebDAVShelfProgressRepository
{
  func stage(_ candidate: ShelfBookCandidate) async throws -> ShelfBookItem
  func add(
    _ candidate: ShelfBookCandidate,
    groupID: Int
  ) async throws -> ShelfBookItem
  func remove(bookID: LibraryDomain.BookID) async throws
  func shelfBooks() async throws -> [ShelfBookItem]
  func shelfGroups() async throws -> [ShelfGroupItem]
  func book(forURL bookURL: String) async throws -> ShelfBookItem?
  func book(id: LibraryDomain.BookID) async throws -> ShelfBookItem?
  func updateBookInfo(
    bookID: LibraryDomain.BookID,
    candidate: ShelfBookCandidate
  ) async throws -> ShelfBookItem
  func updateBookMetadata(
    bookID: LibraryDomain.BookID,
    update: BookMetadataUpdate
  ) async throws -> ShelfBookItem
  func updateWebDAVBookState(
    bookID: LibraryDomain.BookID,
    sourceID: String,
    lastCheckTime: Int64
  ) async throws -> ShelfBookItem
  func chapters(bookID: LibraryDomain.BookID) async throws
    -> [LibraryDomain.BookChapter]
  func applyTOCUpdate(
    bookID: LibraryDomain.BookID,
    update: LibraryDomain.ChapterTOCUpdate,
    bookVariables: [String: String]?,
    tocURL: String?
  ) async throws -> [LibraryDomain.BookChapter]
  func saveReadingProgress(
    bookID: LibraryDomain.BookID,
    progress: ReadingProgress
  ) async throws
  func setReversesTableOfContents(
    bookID: LibraryDomain.BookID,
    enabled: Bool
  ) async throws -> ShelfBookItem
  func setBookTTSEngine(
    bookID: LibraryDomain.BookID,
    value: String?
  ) async throws -> ShelfBookItem
  func setBookImageStyle(
    bookID: LibraryDomain.BookID,
    value: String?
  ) async throws -> ShelfBookItem
  func applySourceSwitch(
    bookID: LibraryDomain.BookID,
    candidate: ShelfBookCandidate,
    chapters: [LibraryDomain.BookChapter],
    progress: ReadingProgress,
    persist: Bool
  ) async throws -> ShelfBookItem
  func shelfSortMode(groupID: Int?) async throws -> ShelfSortMode
  func setShelfSortMode(
    _ mode: ShelfSortMode,
    groupID: Int?
  ) async throws
  func applyShelfMutation(
    _ mutation: ShelfBatchMutation,
    bookID: LibraryDomain.BookID
  ) async throws
  func setShelfOrder(
    _ bookIDs: [LibraryDomain.BookID]
  ) async throws
  func importLocalText(
    candidate: ShelfBookCandidate,
    chapters: [LocalTextChapter]
  ) async throws -> ShelfBookItem
  func rebuildLocalText(
    bookID: LibraryDomain.BookID,
    chapters: [LocalTextChapter],
    splitsLongChapters: Bool
  ) async throws -> ShelfBookItem
  func rebuildLocalText(
    bookID: LibraryDomain.BookID,
    chapters: [LocalTextChapter],
    splitsLongChapters: Bool,
    managedReference: String?
  ) async throws -> ShelfBookItem
  func chapterContent(
    bookID: LibraryDomain.BookID,
    chapterID: LibraryDomain.ChapterID
  ) async throws -> String?
  func saveChapterContent(
    _ content: String,
    bookID: LibraryDomain.BookID,
    chapterID: LibraryDomain.ChapterID
  ) async throws
  func saveSourceChapterTitle(
    _ title: String,
    bookID: LibraryDomain.BookID,
    chapterID: LibraryDomain.ChapterID
  ) async throws
  func clearChapterContents(
    bookID: LibraryDomain.BookID,
    chapterIDs: [LibraryDomain.ChapterID]
  ) async throws
  func saveSourceVariables(
    bookID: LibraryDomain.BookID,
    bookVariables: [String: String]?,
    chapterID: LibraryDomain.ChapterID?,
    chapterVariables: [String: String]?
  ) async throws
  func bookmarks(
    bookID: LibraryDomain.BookID
  ) async throws -> [ReadingBookmark]
  func saveBookmark(_ bookmark: ReadingBookmark) async throws
  func deleteBookmark(id: String) async throws
  func searchHistory() async throws -> [SearchHistoryEntry]
  func upsertSearchHistory(_ entry: SearchHistoryEntry) async throws
  func reset() async throws
}

public extension BookShelfRepository {
  func records(bookName: String) async throws -> [ReadRecord] {
    []
  }

  func upsert(_ record: ReadRecord) async throws {}

  func searchHistory() async throws -> [SearchHistoryEntry] { [] }

  func upsertSearchHistory(_ entry: SearchHistoryEntry) async throws {}

  func shelfGroups() async throws -> [ShelfGroupItem] {
    []
  }

  func updateBookInfo(
    bookID: LibraryDomain.BookID,
    candidate: ShelfBookCandidate
  ) async throws -> ShelfBookItem {
    try await stage(candidate)
  }

  func updateBookMetadata(
    bookID: LibraryDomain.BookID,
    update: BookMetadataUpdate
  ) async throws -> ShelfBookItem {
    guard let current = try await book(id: bookID) else {
      throw ShelfMutationFailure.missingBook
    }
    let candidate = current.candidate
    return try await updateBookInfo(
      bookID: bookID,
      candidate: ShelfBookCandidate(
        name: update.name,
        author: update.author,
        kind: candidate.kind,
        lastChapter: candidate.lastChapter,
        intro: candidate.intro,
        bookURL: candidate.bookURL,
        tocURL: candidate.tocURL,
        bookRequestExpression: candidate.bookRequestExpression,
        coverURL: candidate.coverURL,
        customCoverURL:
          update.coverURL == candidate.coverURL
          ? nil
          : update.coverURL,
        customIntro: update.intro,
        originName: candidate.originName,
        sourceID: candidate.sourceID,
        variables: candidate.variables
      )
    )
  }

  func updateWebDAVBookState(
    bookID: LibraryDomain.BookID,
    sourceID: String,
    lastCheckTime: Int64
  ) async throws -> ShelfBookItem {
    throw ShelfMutationFailure.missingBook
  }

  func applyTOCUpdate(
    bookID: LibraryDomain.BookID,
    update: LibraryDomain.ChapterTOCUpdate,
    bookVariables: [String: String]?
  ) async throws -> [LibraryDomain.BookChapter] {
    try await applyTOCUpdate(
      bookID: bookID,
      update: update,
      bookVariables: bookVariables,
      tocURL: nil
    )
  }

  func applyTOCUpdate(
    bookID: LibraryDomain.BookID,
    update: LibraryDomain.ChapterTOCUpdate
  ) async throws -> [LibraryDomain.BookChapter] {
    try await applyTOCUpdate(
      bookID: bookID,
      update: update,
      bookVariables: nil,
      tocURL: nil
    )
  }

  func saveReadingProgress(
    bookID: LibraryDomain.BookID,
    progress: ReadingProgress
  ) async throws {}

  func setReversesTableOfContents(
    bookID: LibraryDomain.BookID,
    enabled: Bool
  ) async throws -> ShelfBookItem {
    guard let book = try await book(id: bookID) else {
      throw ShelfMutationFailure.missingBook
    }
    return book
  }

  func setBookTTSEngine(
    bookID: LibraryDomain.BookID,
    value: String?
  ) async throws -> ShelfBookItem {
    guard let book = try await book(id: bookID) else {
      throw ShelfMutationFailure.missingBook
    }
    return book
  }

  func setBookImageStyle(
    bookID: LibraryDomain.BookID,
    value: String?
  ) async throws -> ShelfBookItem {
    guard let book = try await book(id: bookID) else {
      throw ShelfMutationFailure.missingBook
    }
    return book
  }

  func shelfSortMode(groupID: Int?) async throws -> ShelfSortMode {
    .recentlyRead
  }

  func setShelfSortMode(
    _ mode: ShelfSortMode,
    groupID: Int?
  ) async throws {}

  func applyShelfMutation(
    _ mutation: ShelfBatchMutation,
    bookID: LibraryDomain.BookID
  ) async throws {
    if case .delete = mutation {
      try await remove(bookID: bookID)
    }
  }

  func setShelfOrder(
    _ bookIDs: [LibraryDomain.BookID]
  ) async throws {}

  func importLocalText(
    candidate: ShelfBookCandidate,
    chapters: [LocalTextChapter]
  ) async throws -> ShelfBookItem {
    throw BookImportFailure.unsupportedRepository
  }

  func rebuildLocalText(
    bookID: LibraryDomain.BookID,
    chapters: [LocalTextChapter],
    splitsLongChapters: Bool
  ) async throws -> ShelfBookItem {
    throw BookImportFailure.unsupportedRepository
  }

  func rebuildLocalText(
    bookID: LibraryDomain.BookID,
    chapters: [LocalTextChapter],
    splitsLongChapters: Bool,
    managedReference: String?
  ) async throws -> ShelfBookItem {
    try await rebuildLocalText(
      bookID: bookID,
      chapters: chapters,
      splitsLongChapters: splitsLongChapters
    )
  }

  func chapterContent(
    bookID: LibraryDomain.BookID,
    chapterID: LibraryDomain.ChapterID
  ) async throws -> String? {
    nil
  }

  func saveChapterContent(
    _ content: String,
    bookID: LibraryDomain.BookID,
    chapterID: LibraryDomain.ChapterID
  ) async throws {
    throw BookImportFailure.unsupportedRepository
  }

  func saveSourceChapterTitle(
    _ title: String,
    bookID: LibraryDomain.BookID,
    chapterID: LibraryDomain.ChapterID
  ) async throws {}

  func clearChapterContents(
    bookID: LibraryDomain.BookID,
    chapterIDs: [LibraryDomain.ChapterID]
  ) async throws {
    throw BookImportFailure.unsupportedRepository
  }

  func saveSourceVariables(
    bookID: LibraryDomain.BookID,
    bookVariables: [String: String]?,
    chapterID: LibraryDomain.ChapterID?,
    chapterVariables: [String: String]?
  ) async throws {}

  func bookmarks(
    bookID: LibraryDomain.BookID
  ) async throws -> [ReadingBookmark] {
    []
  }

  func saveBookmark(_ bookmark: ReadingBookmark) async throws {
    throw BookImportFailure.unsupportedRepository
  }

  func deleteBookmark(id: String) async throws {
    throw BookImportFailure.unsupportedRepository
  }
}

@MainActor
@Observable
public final class ShelfLibrary {
  public private(set) var books: [ShelfBookItem] = []
  public private(set) var groups: [ShelfGroupItem] = []
  public internal(set) var errorMessage: String?
  public private(set) var selectedGroupID: Int?
  public private(set) var sortMode: ShelfSortMode = .recentlyRead
  public private(set) var lastBatchReport: ShelfBatchReport?
  public private(set) var lastLocalArchiveImportReport: LocalArchiveImportReport?
  public internal(set) var offlineCacheState: OfflineCacheState = .idle
  public internal(set) var offlineCacheProgress = 0
  public internal(set) var lastOfflineCacheReport: OfflineCacheReport?
  public private(set) var searchHistory: [SearchHistoryEntry] = []

  let repository: any BookShelfRepository
  private var allBooks: [ShelfBookItem] = []
  private let readRecordDeviceID: String
  private var readRecordSession: ReadRecordSession?

  public init(
    repository: any BookShelfRepository,
    readRecordDeviceID: String = "ios"
  ) {
    self.repository = repository
    self.readRecordDeviceID = readRecordDeviceID
  }

  public func beginReadingRecord(
    bookName: String,
    enabled: Bool = true,
    atMilliseconds nowMilliseconds: Int64? = nil
  ) async {
    guard enabled else {
      readRecordSession = nil
      return
    }
    guard !bookName.isEmpty else { return }
    if readRecordSession?.bookName == bookName { return }
    if readRecordSession != nil {
      await settleReadingRecord(atMilliseconds: nowMilliseconds)
    }
    do {
      let records = try await repository.records(bookName: bookName)
      readRecordSession = NativeReadRecordPolicy.resetSession(
        records: records,
        bookName: bookName,
        deviceID: readRecordDeviceID,
        readStartTimeMilliseconds: nowMilliseconds ?? Self.nowMilliseconds
      )
    } catch {
      readRecordSession = nil
    }
  }

  public func settleReadingRecord(
    enabled: Bool = true,
    atMilliseconds nowMilliseconds: Int64? = nil
  ) async {
    guard let session = readRecordSession else { return }
    readRecordSession = nil
    guard enabled else { return }
    let update = NativeReadRecordPolicy.settle(
      session: session,
      nowMilliseconds: nowMilliseconds ?? Self.nowMilliseconds
    )
    guard let record = update.recordToPersist else { return }
    try? await repository.upsert(record)
  }

  private static var nowMilliseconds: Int64 {
    Int64(Date().timeIntervalSince1970 * 1_000)
  }

  public func reloadSearchHistory() async {
    searchHistory = (try? await repository.searchHistory()) ?? []
  }

  public func recordSearchKeyword(
    _ keyword: String,
    atMilliseconds nowMilliseconds: Int64? = nil
  ) async {
    let word = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !word.isEmpty else { return }
    let existing = (try? await repository.searchHistory())?
      .first { $0.word == word }
    let entry = SearchHistoryEntry(
      word: word,
      usage: (existing?.usage ?? 0) + 1,
      lastUseTime: nowMilliseconds ?? Self.nowMilliseconds
    )
    try? await repository.upsertSearchHistory(entry)
    await reloadSearchHistory()
  }

  public func reload() async {
    do {
      allBooks = try await repository.shelfBooks()
      groups = try await repository.shelfGroups()
      sortMode = try await repository.shelfSortMode(
        groupID: selectedGroupID
      )
      projectBooks()
      errorMessage = nil
    } catch {
      errorMessage = "无法读取书架"
    }
  }

  @discardableResult
  public func stage(_ candidate: ShelfBookCandidate) async -> ShelfBookItem? {
    do {
      let item = try await repository.stage(candidate)
      errorMessage = nil
      return item
    } catch {
      errorMessage = "无法暂存书籍"
      return nil
    }
  }

  public func add(
    _ candidate: ShelfBookCandidate,
    groupID: Int = 0
  ) async {
    do {
      _ = try await repository.add(candidate, groupID: groupID)
      await reload()
      errorMessage = nil
    } catch {
      errorMessage = "无法加入书架"
    }
  }

  public func remove(_ item: ShelfBookItem) async {
    do {
      try await repository.remove(bookID: item.id)
      await reload()
      errorMessage = nil
    } catch {
      errorMessage = "无法移出书架"
    }
  }

  public func item(forURL bookURL: String) async -> ShelfBookItem? {
    try? await repository.book(forURL: bookURL)
  }

  public func item(id: LibraryDomain.BookID) async -> ShelfBookItem? {
    try? await repository.book(id: id)
  }

  @discardableResult
  public func markWebDAVOrigin(
    for book: ShelfBookItem,
    remoteURL: URL,
    serverID: Int64
  ) async -> ShelfBookItem? {
    do {
      let updated = try await repository.updateBookInfo(
        bookID: book.id,
        candidate: AndroidWebDAVBookOrigin.applying(
          to: book.candidate,
          remoteURL: remoteURL,
          serverID: serverID
        )
      )
      let checked = try await repository.updateWebDAVBookState(
        bookID: updated.id,
        sourceID: updated.candidate.sourceID,
        lastCheckTime: Self.nowMilliseconds
      )
      if checked.membership.isInBookshelf {
        await reload()
      }
      errorMessage = nil
      return checked
    } catch {
      errorMessage = "无法保存 WebDAV 书籍来源"
      return nil
    }
  }

  @discardableResult
  public func updateWebDAVBookState(
    bookID: LibraryDomain.BookID,
    sourceID: String,
    lastCheckTime: Int64
  ) async -> ShelfBookItem? {
    do {
      let updated = try await repository.updateWebDAVBookState(
        bookID: bookID,
        sourceID: sourceID,
        lastCheckTime: lastCheckTime
      )
      if updated.membership.isInBookshelf {
        await reload()
      }
      errorMessage = nil
      return updated
    } catch {
      errorMessage = "无法保存 WebDAV 检查状态"
      return nil
    }
  }

  @discardableResult
  public func refreshBookInfo(
    _ book: ShelfBookItem,
    infoLoader: any BookInfoLoading,
    chapterLoader: any BookChapterLoading
  ) async -> ShelfBookItem? {
    do {
      let candidate = try await infoLoader.load(book: book)
      let updated = try await repository.updateBookInfo(
        bookID: book.id,
        candidate: candidate
      )
      let existing = try await repository.chapters(bookID: book.id)
      let fetched = try await chapterLoader.load(book: updated)
      let update = ChapterTOCUpdatePolicy.shelfUpdate(
        existing: existing,
        fetched: fetched.chapters
      )
      _ = try await repository.applyTOCUpdate(
        bookID: book.id,
        update: update,
        bookVariables: fetched.bookVariables,
        tocURL: fetched.tocURL
      )
      let refreshed = try await repository.book(id: book.id)
      if refreshed?.membership.isInBookshelf == true {
        await reload()
      }
      errorMessage = update.updateError
        ? "目录为空，已保留原目录"
        : nil
      return refreshed
    } catch {
      errorMessage = "书籍信息刷新失败"
      return nil
    }
  }

  @discardableResult
  public func updateBookMetadata(
    bookID: LibraryDomain.BookID,
    update: BookMetadataUpdate
  ) async -> ShelfBookItem? {
    do {
      let updated = try await repository.updateBookMetadata(
        bookID: bookID,
        update: update
      )
      if updated.membership.isInBookshelf {
        await reload()
      }
      errorMessage = nil
      return updated
    } catch {
      errorMessage = "无法保存书籍信息"
      return nil
    }
  }

  @discardableResult
  public func setBookCustomVariable(
    _ value: String,
    bookID: LibraryDomain.BookID
  ) async -> ShelfBookItem? {
    guard let current = try? await repository.book(id: bookID) else {
      errorMessage = "书籍不存在"
      return nil
    }
    var variables = current.candidate.variables
    variables["custom"] = value
    do {
      try await repository.saveSourceVariables(
        bookID: bookID,
        bookVariables: variables,
        chapterID: nil,
        chapterVariables: nil
      )
      let updated = try await repository.book(id: bookID)
      if current.membership.isInBookshelf {
        await reload()
      }
      errorMessage = nil
      return updated
    } catch {
      errorMessage = "无法保存书籍变量"
      return nil
    }
  }

  @discardableResult
  public func importLocalText(
    fileName: String,
    managedReference: String,
    data: Data
  ) async -> ShelfBookItem? {
    await importLocalBook(
      fileName: fileName,
      managedReference: managedReference,
      payload: .text(data)
    )
  }

  @discardableResult
  public func importLocalBook(
    fileName: String,
    managedReference: String,
    payload: LocalBookPayload,
    sourceID: String = "local-file"
  ) async -> ShelfBookItem? {
    let metadata = LocalBookImporter.importDocument(
      LocalBookImportInput(
        opaqueReference: managedReference,
        fileName: fileName,
        byteCount: payload.byteCount,
        existingBook: nil
      )
    )
    guard let imported = metadata.books.first else {
      errorMessage = metadata.exception == .emptyFile
        ? "不能导入空文件"
        : "无法识别本地书籍"
      return nil
    }
    do {
      let parsed: (name: String, author: String, kind: String, document: LocalTextBookDocument)
      switch payload {
      case .text(let data):
        guard fileName.lowercased().hasSuffix(".txt") else {
          errorMessage = "文件格式与内容不匹配"
          return nil
        }
        parsed = (
          imported.name,
          imported.author,
          "本地 TXT",
          try LocalTextBookParser.parse(
            data,
            tocRules: try await repository.localTextTOCRules()
          )
        )
      case .epub(let members):
        guard fileName.lowercased().hasSuffix(".epub") else {
          errorMessage = "文件格式与内容不匹配"
          return nil
        }
        let epub = try EPUBBookParser.parse(
          members: members,
          fallbackTitle: fileName
        )
        parsed = (
          epub.title,
          epub.author,
          "本地 EPUB",
          LocalTextBookDocument(chapters: epub.chapters)
        )
      }
      let item = try await repository.importLocalText(
        candidate: ShelfBookCandidate(
          name: parsed.name,
          author: parsed.author,
          kind: parsed.kind,
          lastChapter: parsed.document.chapters.last?.title ?? "",
          intro: parsed.document.chapters.first?.content.prefix(500)
            .description ?? "",
          bookURL: managedReference,
          coverURL: nil,
          originName: fileName,
          sourceID: sourceID
        ),
        chapters: parsed.document.chapters
      )
      await reload()
      errorMessage = nil
      return item
    } catch LocalTextBookFailure.emptyFile {
      errorMessage = "不能导入空文件"
    } catch LocalTextBookFailure.unsupportedEncoding {
      errorMessage = "无法识别 TXT 编码"
    } catch let error as EPUBBookFailure {
      errorMessage = "无法解析 EPUB：\(error)"
    } catch {
      errorMessage = "本地书籍导入失败"
    }
    return nil
  }

  @discardableResult
  public func importLocalArchive(
    archiveName: String,
    items: [LocalArchiveImportItem],
    skipped: [LocalArchiveSkippedEntry]
  ) async -> LocalArchiveImportReport {
    let sourceID = AndroidLocalArchiveBookOrigin.encode(
      archiveName: archiveName
    )
    var imported: [LocalArchiveImportedBook] = []
    var failures: [LocalArchiveEntryFailure] = []
    for item in items {
      if let book = await importLocalBook(
        fileName: item.entry.fileName,
        managedReference: item.managedReference,
        payload: item.payload,
        sourceID: sourceID
      ) {
        imported.append(
          LocalArchiveImportedBook(
            entryPath: item.entry.path,
            bookID: book.id,
            bookName: book.candidate.name
          )
        )
      } else {
        failures.append(
          LocalArchiveEntryFailure(
            entryPath: item.entry.path,
            message: errorMessage ?? "导入失败"
          )
        )
      }
    }
    let report = LocalArchiveImportReport(
      archiveName: archiveName,
      imported: imported,
      failures: failures,
      skipped: skipped
    )
    lastLocalArchiveImportReport = report
    errorMessage = imported.isEmpty ? "压缩包内没有可导入的书籍" : nil
    return report
  }

  @discardableResult
  public func setLocalTextLongChapterSplitting(
    _ enabled: Bool,
    bookID: LibraryDomain.BookID,
    data: Data
  ) async -> ShelfBookItem? {
    guard
      let current = try? await repository.book(id: bookID),
      AndroidWebDAVBookOrigin.isLocalSource(current.candidate.sourceID)
    else {
      errorMessage = "仅本地 TXT 支持拆分长章节"
      return nil
    }
    do {
      let document = try LocalTextBookParser.parse(
        data,
        splitLongChapters: enabled,
        tocRules: try await repository.localTextTOCRules()
      )
      let updated = try await repository.rebuildLocalText(
        bookID: bookID,
        chapters: document.chapters,
        splitsLongChapters: enabled
      )
      await reload()
      errorMessage = nil
      return updated
    } catch {
      errorMessage = "无法重新解析本地 TXT"
      return nil
    }
  }

  @discardableResult
  public func refreshLocalText(
    bookID: LibraryDomain.BookID,
    data: Data
  ) async -> ShelfBookItem? {
    guard
      let current = try? await repository.book(id: bookID),
      AndroidWebDAVBookOrigin.isLocalSource(current.candidate.sourceID)
    else {
      errorMessage = "仅本地 TXT 支持重新读取"
      return nil
    }
    return await setLocalTextLongChapterSplitting(
      current.splitsLongChapters,
      bookID: bookID,
      data: data
    )
  }

  @discardableResult
  public func restoreWebDAVLocalText(
    bookID: LibraryDomain.BookID,
    managedReference: String,
    data: Data,
    splitsLongChapters: Bool? = nil
  ) async -> ShelfBookItem? {
    guard
      let current = try? await repository.book(id: bookID),
      AndroidWebDAVBookOrigin.decode(current.candidate.sourceID) != nil
    else {
      errorMessage = "书籍没有可恢复的 WebDAV 来源"
      return nil
    }
    do {
      let shouldSplit = splitsLongChapters ?? current.splitsLongChapters
      let document = try LocalTextBookParser.parse(
        data,
        splitLongChapters: shouldSplit,
        tocRules: try await repository.localTextTOCRules()
      )
      let updated = try await repository.rebuildLocalText(
        bookID: bookID,
        chapters: document.chapters,
        splitsLongChapters: shouldSplit,
        managedReference: managedReference
      )
      await reload()
      errorMessage = nil
      return updated
    } catch {
      errorMessage = "无法恢复 WebDAV 本地书"
      return nil
    }
  }

  public func readerContentLoader(
    fallback: any ReaderContentLoading
  ) -> any ReaderContentLoading {
    ReplacementNormalizingReaderContentLoader(
      base: RepositoryReaderContentLoader(
        repository: repository,
        fallback: fallback
      ),
      rules: repository
    )
  }

  public func chapterSession(
    loader: any BookChapterLoading
  ) -> ChapterTOCSession {
    ChapterTOCSession(repository: repository, loader: loader)
  }

  public func chapter(
    bookID: LibraryDomain.BookID,
    chapterID: LibraryDomain.ChapterID
  ) async -> LibraryDomain.BookChapter? {
    try? await repository.chapters(bookID: bookID).first {
      $0.id == chapterID
    }
  }

  public func chapters(
    bookID: LibraryDomain.BookID
  ) async -> [LibraryDomain.BookChapter] {
    (try? await repository.chapters(bookID: bookID)) ?? []
  }

  @discardableResult
  public func setReversesTableOfContents(
    bookID: LibraryDomain.BookID,
    enabled: Bool
  ) async -> ShelfBookItem? {
    do {
      let updated = try await repository.setReversesTableOfContents(
        bookID: bookID,
        enabled: enabled
      )
      if let index = books.firstIndex(where: { $0.id == bookID }) {
        books[index] = updated
      }
      allBooks = try await repository.shelfBooks()
      projectBooks()
      errorMessage = nil
      return updated
    } catch {
      errorMessage = "无法切换目录顺序"
      return nil
    }
  }

  @discardableResult
  public func setBookTTSEngine(
    bookID: LibraryDomain.BookID,
    value: String?
  ) async -> ShelfBookItem? {
    do {
      let updated = try await repository.setBookTTSEngine(
        bookID: bookID,
        value: value
      )
      if let index = books.firstIndex(where: { $0.id == bookID }) {
        books[index] = updated
      }
      allBooks = try await repository.shelfBooks()
      projectBooks()
      errorMessage = nil
      return updated
    } catch {
      errorMessage = "无法保存本书朗读引擎"
      return nil
    }
  }

  @discardableResult
  public func setBookImageStyle(
    bookID: LibraryDomain.BookID,
    value: String?
  ) async -> ShelfBookItem? {
    do {
      let updated = try await repository.setBookImageStyle(
        bookID: bookID,
        value: value
      )
      if let index = books.firstIndex(where: { $0.id == bookID }) {
        books[index] = updated
      }
      allBooks = try await repository.shelfBooks()
      projectBooks()
      errorMessage = nil
      return updated
    } catch {
      errorMessage = "无法保存本书图片样式"
      return nil
    }
  }

  public func cacheChapterContent(
    _ content: String,
    bookID: LibraryDomain.BookID,
    chapterID: LibraryDomain.ChapterID
  ) async {
    do {
      try await repository.saveChapterContent(
        content,
        bookID: bookID,
        chapterID: chapterID
      )
      errorMessage = nil
    } catch {
      errorMessage = "无法缓存章节正文"
    }
  }

  @discardableResult
  public func invalidateReaderContent(
    bookID: LibraryDomain.BookID,
    currentChapterID: LibraryDomain.ChapterID,
    scope: ReaderContentRefreshScope
  ) async -> Bool {
    do {
      let chapters = try await repository.chapters(bookID: bookID)
        .sorted {
          if $0.index == $1.index {
            return $0.id.rawValue < $1.id.rawValue
          }
          return $0.index < $1.index
        }
      guard
        let currentIndex = chapters.firstIndex(where: {
          $0.id == currentChapterID
        })
      else {
        errorMessage = "当前章节不存在"
        return false
      }
      let targets: [LibraryDomain.ChapterID]
      switch scope {
      case .current:
        targets = [currentChapterID]
      case .currentAndAfter:
        targets = chapters[currentIndex...].map(\.id)
      case .all:
        targets = chapters.map(\.id)
      }
      try await repository.clearChapterContents(
        bookID: bookID,
        chapterIDs: targets
      )
      errorMessage = nil
      return true
    } catch {
      errorMessage = "无法刷新正文缓存"
      return false
    }
  }

  @discardableResult
  public func saveReadingProgress(
    bookID: LibraryDomain.BookID,
    chapterIndex: Int,
    characterOffset: Int,
    chapterTitle: String?,
    webDAVConfiguration: WebDAVConnectionConfiguration? = nil,
    webDAVUploader: WebDAVReaderProgressUploadCoordinator? = nil
  ) async -> ReadingProgress? {
    let progress = ReadingProgress(
      position: ReadingPosition(
        chapterIndex: max(0, chapterIndex),
        characterOffset: max(0, characterOffset)
      ),
      chapterTitle: chapterTitle,
      updatedAtMilliseconds: Int64(
        Date().timeIntervalSince1970 * 1_000
      )
    )
    do {
      try await repository.saveReadingProgress(
        bookID: bookID,
        progress: progress
      )
      let persistedBook = try await repository.book(id: bookID)
      if
        let persistedBook,
        let index = books.firstIndex(where: { $0.id == bookID })
      {
        books[index] = persistedBook
      }
      allBooks = try await repository.shelfBooks()
      projectBooks()
      errorMessage = nil
      if
        let persistedBook,
        let webDAVConfiguration,
        let webDAVUploader
      {
        await webDAVUploader.schedule(
          configuration: webDAVConfiguration,
          book: persistedBook,
          progress: progress
        )
      }
      return progress
    } catch {
      errorMessage = "无法保存阅读进度"
      return nil
    }
  }

  @discardableResult
  public func switchSource(
    current: ShelfBookItem,
    candidate: ShelfBookCandidate,
    chapters: [LibraryDomain.BookChapter]
  ) async -> ShelfBookItem? {
    do {
      let latest = try await repository.book(id: current.id) ?? current
      let oldBook = SourceMigrationBook(
        id: latest.id,
        sourceURL: latest.candidate.sourceID,
        title: latest.candidate.name,
        author: latest.candidate.author,
        progress: latest.progress,
        totalChapterCount: latest.chapterCount,
        userState: SourceMigrationUserState(
          groupID: Int64(latest.membership.groupID),
          order: latest.order
        )
      )
      let target = SourceMigrationBook(
        id: latest.id,
        sourceURL: candidate.sourceID,
        title: candidate.name,
        author: candidate.author,
        totalChapterCount: chapters.count
      )
      let targetChapters = chapters.map {
        SourceMigrationChapter(
          id: $0.id,
          title: $0.title,
          index: $0.index
        )
      }
      let migration = try AndroidBookSourceMigrationPolicy.migrate(
        oldBook: oldBook,
        candidate: target,
        targetChapters: targetChapters,
        inBookshelf: latest.membership.isInBookshelf
      )
      guard let progress = migration.book.progress else {
        throw BookSourceSwitchFailure.missingMigratedProgress
      }
      let normalizedChapters = chapters.map {
        LibraryDomain.BookChapter(
          id: $0.id,
          bookID: latest.id,
          sourceID: candidate.sourceID,
          index: $0.index,
          title: $0.title,
          url: $0.url,
          requestExpression: $0.requestExpression,
          isPay: $0.isPay,
          isVIP: $0.isVIP,
          isVolume: $0.isVolume,
          variables: $0.variables
        )
      }
      let tocOrder = ReaderTOCOrderPolicy.migrating(
        normalizedChapters,
        progress: progress,
        reversed: latest.reversesTableOfContents
      )
      let item = try await repository.applySourceSwitch(
        bookID: latest.id,
        candidate: candidate,
        chapters: tocOrder.chapters,
        progress: tocOrder.progress,
        persist: latest.membership.isInBookshelf
      )
      if latest.membership.isInBookshelf {
        await reload()
      }
      errorMessage = nil
      return item
    } catch BookSourceMigrationError.emptyTargetTableOfContents {
      errorMessage = "目标书源目录为空，未执行换源"
      return nil
    } catch {
      errorMessage = "无法切换书源"
      return nil
    }
  }

  public func reset() async {
    try? await repository.reset()
    allBooks = []
    books = []
    groups = []
    selectedGroupID = nil
    sortMode = .recentlyRead
    lastBatchReport = nil
    errorMessage = nil
  }

  public var availableGroupIDs: [Int] {
    availableGroups.map(\.id)
  }

  public var availableGroups: [ShelfGroupItem] {
    let restored = groups.filter { $0.id > 0 && $0.isShown }
    let restoredIDs = Set(restored.map(\.id))
    let inferred = Set(
      allBooks.flatMap { book in
        Self.oneHotGroupIDs(in: book.membership.groupID)
      }
    )
    .subtracting(restoredIDs)
    .map { ShelfGroupItem(id: $0, name: "分组 \($0)") }
    return (restored + inferred).sorted {
      ($0.order, $0.id) < ($1.order, $1.id)
    }
  }

  public func selectGroup(_ groupID: Int?) async {
    selectedGroupID = groupID
    do {
      sortMode = try await repository.shelfSortMode(groupID: groupID)
      projectBooks()
      errorMessage = nil
    } catch {
      errorMessage = "无法读取分组排序"
    }
  }

  public func setSortMode(
    _ mode: ShelfSortMode,
    forCurrentGroup: Bool
  ) async {
    let groupID = forCurrentGroup ? selectedGroupID : nil
    do {
      try await repository.setShelfSortMode(mode, groupID: groupID)
      sortMode = try await repository.shelfSortMode(
        groupID: selectedGroupID
      )
      projectBooks()
      errorMessage = nil
    } catch {
      errorMessage = "无法保存书架排序"
    }
  }

  public func globalShelfSortMode() async -> ShelfSortMode {
    (try? await repository.shelfSortMode(groupID: nil)) ?? .recentlyRead
  }

  public func moveBooks(
    fromOffsets: IndexSet,
    toOffset: Int
  ) async {
    var reordered = books
    let offsets = fromOffsets.filter { reordered.indices.contains($0) }
    let moving = offsets.map { reordered[$0] }
    for offset in offsets.reversed() {
      reordered.remove(at: offset)
    }
    let removedBeforeDestination = offsets.filter { $0 < toOffset }.count
    let destination = min(
      max(0, toOffset - removedBeforeDestination),
      reordered.count
    )
    reordered.insert(contentsOf: moving, at: destination)
    books = reordered
    do {
      try await repository.setShelfOrder(reordered.map(\.id))
      try await repository.setShelfSortMode(
        .manual,
        groupID: selectedGroupID
      )
      allBooks = try await repository.shelfBooks()
      sortMode = .manual
      projectBooks()
      errorMessage = nil
    } catch {
      errorMessage = "无法保存手动排序"
      await reload()
    }
  }

  @discardableResult
  public func performBatch(
    _ mutation: ShelfBatchMutation,
    bookIDs: [LibraryDomain.BookID]
  ) async -> ShelfBatchReport {
    let repository = self.repository
    let report = await ShelfBatchExecution.run(bookIDs: bookIDs) { bookID in
      try await repository.applyShelfMutation(mutation, bookID: bookID)
      return .committed
    }
    lastBatchReport = report
    await reload()
    return report
  }

  @discardableResult
  public func setCanUpdate(
    _ canUpdate: Bool,
    bookID: LibraryDomain.BookID
  ) async -> ShelfBookItem? {
    let report = await performBatch(
      .setCanUpdate(canUpdate),
      bookIDs: [bookID]
    )
    guard report.committedBookIDs == [bookID] else {
      return nil
    }
    return await item(id: bookID)
  }

  @discardableResult
  public func clearCache(
    bookID: LibraryDomain.BookID
  ) async -> Bool {
    let report = await performBatch(
      .clearCache,
      bookIDs: [bookID]
    )
    return report.committedBookIDs == [bookID]
  }

  @discardableResult
  public func switchSources(
    bookIDs: [LibraryDomain.BookID],
    targetSourceID: String,
    resolve: @escaping @Sendable (
      ShelfBookItem
    ) async throws -> (
      candidate: ShelfBookCandidate,
      chapters: [LibraryDomain.BookChapter]
    )
  ) async -> ShelfBatchReport {
    let repository = self.repository
    let report = await ShelfBatchExecution.run(bookIDs: bookIDs) { bookID in
      guard let current = try await repository.book(id: bookID) else {
        return .failed(.operationFailed)
      }
      if current.candidate.bookURL.hasPrefix("file://") {
        return .skipped(.localBook)
      }
      if current.candidate.sourceID == targetSourceID {
        return .skipped(.alreadyUsesTargetSource)
      }
      do {
        let resolved = try await resolve(current)
        let policy = try Self.sourceMigration(
          current: current,
          candidate: resolved.candidate,
          chapters: resolved.chapters
        )
        _ = try await repository.applySourceSwitch(
          bookID: current.id,
          candidate: resolved.candidate,
          chapters: policy.chapters,
          progress: policy.progress,
          persist: true
        )
        return .committed
      } catch BookSourceMigrationError.emptyTargetTableOfContents {
        return .failed(.tableOfContentsFailed)
      } catch {
        return .failed(.searchFailed)
      }
    }
    lastBatchReport = report
    await reload()
    return report
  }

  private func projectBooks() {
    let filtered = allBooks.filter {
      guard let selectedGroupID else { return true }
      return $0.membership.isMember(of: selectedGroupID)
    }
    let orderedIDs = ShelfBookOrdering.sort(
      filtered.map(\.presentation),
      by: sortMode
    ).map(\.id)
    let byID = Dictionary(uniqueKeysWithValues: filtered.map { ($0.id, $0) })
    books = orderedIDs.compactMap { byID[$0] }
  }

  nonisolated private static func oneHotGroupIDs(in groupMask: Int) -> [Int] {
    guard groupMask > 0 else { return [] }
    return (0..<Int.bitWidth - 1).compactMap { offset in
      let candidate = 1 << offset
      return groupMask & candidate == 0 ? nil : candidate
    }
  }

  nonisolated private static func sourceMigration(
    current: ShelfBookItem,
    candidate: ShelfBookCandidate,
    chapters: [LibraryDomain.BookChapter]
  ) throws -> (
    progress: ReadingProgress,
    chapters: [LibraryDomain.BookChapter]
  ) {
    let oldBook = SourceMigrationBook(
      id: current.id,
      sourceURL: current.candidate.sourceID,
      title: current.candidate.name,
      author: current.candidate.author,
      progress: current.progress,
      totalChapterCount: current.chapterCount,
      userState: SourceMigrationUserState(
        groupID: Int64(current.membership.groupID),
        order: current.order
      )
    )
    let target = SourceMigrationBook(
      id: current.id,
      sourceURL: candidate.sourceID,
      title: candidate.name,
      author: candidate.author,
      totalChapterCount: chapters.count
    )
    let migration = try AndroidBookSourceMigrationPolicy.migrate(
      oldBook: oldBook,
      candidate: target,
      targetChapters: chapters.map {
        SourceMigrationChapter(id: $0.id, title: $0.title, index: $0.index)
      },
      inBookshelf: true
    )
    guard let progress = migration.book.progress else {
      throw BookSourceSwitchFailure.missingMigratedProgress
    }
    let normalizedChapters = chapters.map {
        LibraryDomain.BookChapter(
          id: $0.id,
          bookID: current.id,
          sourceID: candidate.sourceID,
          index: $0.index,
          title: $0.title,
          url: $0.url,
          requestExpression: $0.requestExpression,
          isPay: $0.isPay,
          isVIP: $0.isVIP,
          isVolume: $0.isVolume,
          variables: $0.variables
        )
      }
    let tocOrder = ReaderTOCOrderPolicy.migrating(
      normalizedChapters,
      progress: progress,
      reversed: current.reversesTableOfContents
    )
    return (tocOrder.progress, tocOrder.chapters)
  }
}

public enum BookSourceSwitchFailure: Error, Equatable, Sendable {
  case missingBook
  case missingMigratedProgress
}
