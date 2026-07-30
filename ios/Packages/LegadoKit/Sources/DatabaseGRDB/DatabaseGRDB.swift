import AppUseCases
import Foundation
import GRDB
import LibraryDomain

/// Keeps GRDB types behind the platform persistence adapter boundary.
public enum DatabaseGRDBRuntime {
  public static func verifyInMemoryDatabase() throws -> Bool {
    let queue = try DatabaseQueue(path: ":memory:")
    try queue.write { database in
      try database.execute(
        sql: """
          CREATE TABLE dependency_probe (
            id INTEGER PRIMARY KEY,
            value TEXT NOT NULL
          )
          """
      )
      try database.execute(
        sql: "INSERT INTO dependency_probe (value) VALUES (?)",
        arguments: ["ready"]
      )
    }
    return try queue.read { database in
      try String.fetchOne(
        database,
        sql: "SELECT value FROM dependency_probe LIMIT 1"
      ) == "ready"
    }
  }

  public static func verifyShelfPersistenceAcrossReopen() async throws -> Bool {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("sqlite")
      .path
    let candidate = ShelfBookCandidate(
      name: "星河纪事",
      author: "林舟",
      kind: "科幻",
      lastChapter: "第二章",
      intro: "简介",
      bookURL: "http://legado.local/books/star-river",
      coverURL: nil,
      originName: "本地书源"
    )
    let first = try GRDBBookShelfRepository(path: path)
    let staged = try await first.stage(candidate)
    guard
      !staged.membership.isInBookshelf,
      try await first.shelfBooks().isEmpty
    else {
      return false
    }
    let added = try await first.add(candidate, groupID: 0)
    guard
      added.membership.isInBookshelf,
      added.membership.groupID == 0
    else {
      return false
    }
    let reopened = try GRDBBookShelfRepository(path: path)
    let books = try await reopened.shelfBooks()
    return books.count == 1
      && books.first?.id == added.id
      && books.first?.candidate.name == "星河纪事"
  }

  public static func verifyTOCPersistenceAcrossReopen() async throws -> Bool {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("sqlite")
      .path
    let repository = try GRDBBookShelfRepository(path: path)
    let book = try await repository.stage(
      ShelfBookCandidate(
        name: "星河纪事",
        author: "林舟",
        kind: "科幻",
        lastChapter: "第三章",
        intro: "",
        bookURL: "http://sourcelab.test/books/star-river",
        coverURL: nil,
        originName: "测试源",
        sourceID: "source://local"
      )
    )
    let chapters = (0..<3).map { index in
      BookChapter(
        id: ChapterID(
          sourceID: "source://local",
          chapterURL: "http://sourcelab.test/chapters/\(index + 1)"
        ),
        bookID: book.id,
        sourceID: "source://local",
        index: index,
        title: "第\(index + 1)章",
        url: "http://sourcelab.test/chapters/\(index + 1)"
      )
    }
    guard
      try await repository.applyTOCUpdate(
        bookID: book.id,
        update: .replaced(previousCount: 0, chapters: chapters)
      ) == chapters,
      try await repository.applyTOCUpdate(
        bookID: book.id,
        update: .preserved(failure: .empty, chapters: chapters)
      ) == chapters
    else {
      return false
    }
    let reopened = try GRDBBookShelfRepository(path: path)
    let reopenedChapters = try await reopened.chapters(bookID: book.id)
    let reopenedBook = try await reopened.book(id: book.id)
    return reopenedChapters == chapters
      && reopenedBook?.chapterCount == 3
  }

  public static func verifyProgressPersistenceAcrossReopen() async throws
    -> Bool
  {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("sqlite")
      .path
    let repository = try GRDBBookShelfRepository(path: path)
    let book = try await repository.add(
      ShelfBookCandidate(
        name: "星河纪事",
        author: "林舟",
        kind: "科幻",
        lastChapter: "第二章",
        intro: "",
        bookURL: "http://sourcelab.test/books/progress",
        coverURL: nil,
        originName: "测试源"
      ),
      groupID: 0
    )
    let progress = ReadingProgress(
      position: ReadingPosition(
        chapterIndex: 1,
        characterOffset: 128
      ),
      chapterTitle: "第二章 回声",
      updatedAtMilliseconds: 1_234
    )
    try await repository.saveReadingProgress(
      bookID: book.id,
      progress: progress
    )

    let reopened = try GRDBBookShelfRepository(path: path)
    return try await reopened.book(id: book.id)?.progress == progress
  }
}
