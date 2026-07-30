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

  public init(
    id: LibraryDomain.BookID,
    candidate: ShelfBookCandidate,
    membership: ShelfMembership,
    order: Int64,
    chapterCount: Int,
    progress: ReadingProgress? = nil
  ) {
    self.id = id
    self.candidate = candidate
    self.membership = membership
    self.order = order
    self.chapterCount = chapterCount
    self.progress = progress
  }
}

public protocol BookShelfRepository: Sendable {
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
  func reset() async throws
}

public extension BookShelfRepository {
  func saveReadingProgress(
    bookID: LibraryDomain.BookID,
    progress: ReadingProgress
  ) async throws {}
}

@MainActor
@Observable
public final class ShelfLibrary {
  public private(set) var books: [ShelfBookItem] = []
  public private(set) var errorMessage: String?

  private let repository: any BookShelfRepository

  public init(repository: any BookShelfRepository) {
    self.repository = repository
  }

  public func reload() async {
    do {
      books = try await repository.shelfBooks()
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
      books = try await repository.shelfBooks()
      errorMessage = nil
    } catch {
      errorMessage = "无法加入书架"
    }
  }

  public func remove(_ item: ShelfBookItem) async {
    do {
      try await repository.remove(bookID: item.id)
      books = try await repository.shelfBooks()
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
        books = try await repository.shelfBooks()
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
    books = []
    errorMessage = nil
  }
}

public enum BookSourceSwitchFailure: Error, Equatable, Sendable {
  case missingBook
  case missingMigratedProgress
}
