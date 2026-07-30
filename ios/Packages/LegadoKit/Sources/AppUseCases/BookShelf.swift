import Foundation
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
  public let bookRequestExpression: String
  public let coverURL: String?
  public let originName: String
  public let sourceID: String

  public init(
    name: String,
    author: String,
    kind: String,
    lastChapter: String,
    intro: String,
    bookURL: String,
    bookRequestExpression: String? = nil,
    coverURL: String?,
    originName: String,
    sourceID: String = ""
  ) {
    self.name = name
    self.author = author
    self.kind = kind
    self.lastChapter = lastChapter
    self.intro = intro
    self.bookURL = bookURL
    self.bookRequestExpression = bookRequestExpression ?? bookURL
    self.coverURL = coverURL
    self.originName = originName
    self.sourceID = sourceID
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
  public let latestCheckCount: Int
  public let canUpdate: Bool

  public init(
    id: LibraryDomain.BookID,
    candidate: ShelfBookCandidate,
    membership: ShelfMembership,
    order: Int64,
    chapterCount: Int,
    progress: ReadingProgress? = nil,
    latestChapterTime: Int64 = 0,
    latestCheckCount: Int = 0,
    canUpdate: Bool = true
  ) {
    self.id = id
    self.candidate = candidate
    self.membership = membership
    self.order = order
    self.chapterCount = chapterCount
    self.progress = progress
    self.latestChapterTime = latestChapterTime
    self.latestCheckCount = max(0, latestCheckCount)
    self.canUpdate = canUpdate
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

public protocol BookShelfRepository:
  Sendable, ReaderReplacementRuleRepository
{
  func stage(_ candidate: ShelfBookCandidate) async throws -> ShelfBookItem
  func add(
    _ candidate: ShelfBookCandidate,
    groupID: Int
  ) async throws -> ShelfBookItem
  func remove(bookID: LibraryDomain.BookID) async throws
  func shelfBooks() async throws -> [ShelfBookItem]
  func book(forURL bookURL: String) async throws -> ShelfBookItem?
  func book(id: LibraryDomain.BookID) async throws -> ShelfBookItem?
  func chapters(bookID: LibraryDomain.BookID) async throws
    -> [LibraryDomain.BookChapter]
  func applyTOCUpdate(
    bookID: LibraryDomain.BookID,
    update: LibraryDomain.ChapterTOCUpdate
  ) async throws -> [LibraryDomain.BookChapter]
  func saveReadingProgress(
    bookID: LibraryDomain.BookID,
    progress: ReadingProgress
  ) async throws
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
  func chapterContent(
    bookID: LibraryDomain.BookID,
    chapterID: LibraryDomain.ChapterID
  ) async throws -> String?
  func saveChapterContent(
    _ content: String,
    bookID: LibraryDomain.BookID,
    chapterID: LibraryDomain.ChapterID
  ) async throws
  func bookmarks(
    bookID: LibraryDomain.BookID
  ) async throws -> [ReadingBookmark]
  func saveBookmark(_ bookmark: ReadingBookmark) async throws
  func deleteBookmark(id: String) async throws
  func reset() async throws
}

public extension BookShelfRepository {
  func saveReadingProgress(
    bookID: LibraryDomain.BookID,
    progress: ReadingProgress
  ) async throws {}

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
  public internal(set) var errorMessage: String?
  public private(set) var selectedGroupID: Int?
  public private(set) var sortMode: ShelfSortMode = .recentlyRead
  public private(set) var lastBatchReport: ShelfBatchReport?
  public internal(set) var offlineCacheState: OfflineCacheState = .idle
  public internal(set) var offlineCacheProgress = 0
  public internal(set) var lastOfflineCacheReport: OfflineCacheReport?

  let repository: any BookShelfRepository
  private var allBooks: [ShelfBookItem] = []

  public init(repository: any BookShelfRepository) {
    self.repository = repository
  }

  public func reload() async {
    do {
      allBooks = try await repository.shelfBooks()
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
  public func importLocalText(
    fileName: String,
    managedReference: String,
    data: Data
  ) async -> ShelfBookItem? {
    guard fileName.lowercased().hasSuffix(".txt") else {
      errorMessage = "当前只支持真实可解析的 TXT 文件"
      return nil
    }
    let metadata = LocalBookImporter.importDocument(
      LocalBookImportInput(
        opaqueReference: managedReference,
        fileName: fileName,
        byteCount: data.count,
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
      let document = try LocalTextBookParser.parse(data)
      let item = try await repository.importLocalText(
        candidate: ShelfBookCandidate(
          name: imported.name,
          author: imported.author,
          kind: "本地 TXT",
          lastChapter: document.chapters.last?.title ?? "",
          intro: document.chapters.first?.content.prefix(500)
            .description ?? "",
          bookURL: managedReference,
          coverURL: nil,
          originName: fileName,
          sourceID: "local-file"
        ),
        chapters: document.chapters
      )
      await reload()
      errorMessage = nil
      return item
    } catch LocalTextBookFailure.emptyFile {
      errorMessage = "不能导入空文件"
    } catch LocalTextBookFailure.unsupportedEncoding {
      errorMessage = "无法识别 TXT 编码"
    } catch {
      errorMessage = "本地书籍导入失败"
    }
    return nil
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

  public func saveReadingProgress(
    bookID: LibraryDomain.BookID,
    chapterIndex: Int,
    characterOffset: Int,
    chapterTitle: String?
  ) async {
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
      if let index = books.firstIndex(where: { $0.id == bookID }) {
        books[index] = try await repository.book(id: bookID)
          ?? books[index]
      }
      allBooks = try await repository.shelfBooks()
      projectBooks()
      errorMessage = nil
    } catch {
      errorMessage = "无法保存阅读进度"
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
          isPay: $0.isPay,
          isVIP: $0.isVIP,
          isVolume: $0.isVolume
        )
      }
      let item = try await repository.applySourceSwitch(
        bookID: latest.id,
        candidate: candidate,
        chapters: normalizedChapters,
        progress: progress,
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
    selectedGroupID = nil
    sortMode = .recentlyRead
    lastBatchReport = nil
    errorMessage = nil
  }

  public var availableGroupIDs: [Int] {
    Array(
      Set(allBooks.map(\.membership.groupID).filter { $0 > 0 })
    ).sorted()
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
      return $0.membership.groupID == selectedGroupID
    }
    let orderedIDs = ShelfBookOrdering.sort(
      filtered.map(\.presentation),
      by: sortMode
    ).map(\.id)
    let byID = Dictionary(uniqueKeysWithValues: filtered.map { ($0.id, $0) })
    books = orderedIDs.compactMap { byID[$0] }
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
    return (
      progress,
      chapters.map {
        LibraryDomain.BookChapter(
          id: $0.id,
          bookID: current.id,
          sourceID: candidate.sourceID,
          index: $0.index,
          title: $0.title,
          url: $0.url,
          isPay: $0.isPay,
          isVIP: $0.isVIP,
          isVolume: $0.isVolume
        )
      }
    )
  }
}

public enum BookSourceSwitchFailure: Error, Equatable, Sendable {
  case missingBook
  case missingMigratedProgress
}
