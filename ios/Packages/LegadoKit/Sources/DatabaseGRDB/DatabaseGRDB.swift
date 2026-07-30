import AppUseCases
import Foundation
import GRDB

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
}
