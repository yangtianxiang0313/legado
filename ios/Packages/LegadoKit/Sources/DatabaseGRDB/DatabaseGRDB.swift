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

  public static func verifyAtomicSourceSwitchAcrossReopen() async throws
    -> Bool
  {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("sqlite")
      .path
    let repository = try GRDBBookShelfRepository(path: path)
    let old = try await repository.add(
      ShelfBookCandidate(
        name: "星河纪事",
        author: "林舟",
        kind: "科幻",
        lastChapter: "第二章",
        intro: "旧简介",
        bookURL: "http://legado.local/books/old",
        coverURL: nil,
        originName: "旧书源",
        sourceID: "source://old"
      ),
      groupID: 7
    )
    try await repository.saveReadingProgress(
      bookID: old.id,
      progress: ReadingProgress(
        position: ReadingPosition(
          chapterIndex: 1,
          characterOffset: 37
        ),
        chapterTitle: "第二章",
        updatedAtMilliseconds: 123
      )
    )
    let newCandidate = ShelfBookCandidate(
      name: "星河纪事",
      author: "林舟",
      kind: "科幻",
      lastChapter: "第三章",
      intro: "新简介",
      bookURL: "http://legado.local/books/new",
      coverURL: nil,
      originName: "新书源",
      sourceID: "source://new"
    )
    let chapterTitles = ["第一章", "第二章", "第三章"]
    let chapters = chapterTitles.enumerated().map { index, title in
      BookChapter(
        id: ChapterID(
          sourceID: newCandidate.sourceID,
          chapterURL: "\(newCandidate.bookURL)/chapter/\(index)"
        ),
        bookID: old.id,
        sourceID: newCandidate.sourceID,
        index: index,
        title: title,
        url: "\(newCandidate.bookURL)/chapter/\(index)"
      )
    }
    let progress = ReadingProgress(
      position: ReadingPosition(
        chapterIndex: 1,
        characterOffset: 37
      ),
      chapterTitle: "第二章",
      updatedAtMilliseconds: 123
    )
    let library = await ShelfLibrary(repository: repository)
    guard let switched = await library.switchSource(
      current: old,
      candidate: newCandidate,
      chapters: chapters
    ) else {
      return false
    }
    let reopened = try GRDBBookShelfRepository(path: path)
    let stored = try await reopened.book(id: old.id)
    let storedChapters = try await reopened.chapters(bookID: old.id)
    let oldIdentity = try await reopened.book(
      forURL: "http://legado.local/books/old"
    )
    let checks = [
      "switchedIdentity": switched.id == old.id,
      "storedIdentity": stored?.id == old.id,
      "candidate": stored?.candidate == newCandidate,
      "membership": stored?.membership == .member(groupID: 7),
      "progress": stored?.progress == progress,
      "chapters": storedChapters == chapters,
      "oldIdentityRemoved": oldIdentity == nil,
    ]
    if checks.values.contains(false) {
      print(
        "SOURCE_SWITCH_CHECKS:\(checks),"
          + "storedProgress=\(String(describing: stored?.progress)),"
          + "expectedProgress=\(progress)"
      )
    }
    return checks.values.allSatisfy { $0 }
  }
}
