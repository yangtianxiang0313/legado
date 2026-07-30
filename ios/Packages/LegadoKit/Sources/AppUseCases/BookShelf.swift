import Foundation
import LibraryDomain
import Observation

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

  public init(
    id: LibraryDomain.BookID,
    candidate: ShelfBookCandidate,
    membership: ShelfMembership,
    order: Int64,
    chapterCount: Int
  ) {
    self.id = id
    self.candidate = candidate
    self.membership = membership
    self.order = order
    self.chapterCount = chapterCount
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
  func reset() async throws
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

  public func reset() async {
    try? await repository.reset()
    books = []
    errorMessage = nil
  }
}
