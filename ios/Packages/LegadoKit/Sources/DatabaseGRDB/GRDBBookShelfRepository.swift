import AppUseCases
import Foundation
import GRDB
import LibraryDomain

public actor GRDBBookShelfRepository: BookShelfRepository {
  private let database: DatabaseQueue

  public init(path: String) throws {
    database = try DatabaseQueue(path: path)
    try Self.migrator.migrate(database)
  }

  public static func applicationSupport(
    fileManager: FileManager = .default
  ) throws -> GRDBBookShelfRepository {
    let directory = try fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    ).appendingPathComponent("Legado", isDirectory: true)
    try fileManager.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    return try GRDBBookShelfRepository(
      path: directory.appendingPathComponent("library.sqlite").path
    )
  }

  public func stage(
    _ candidate: ShelfBookCandidate
  ) async throws -> ShelfBookItem {
    try await database.write { db in
      if var existing = try BookRecord
        .filter(Column("bookURL") == candidate.bookURL)
        .fetchOne(db)
      {
        existing.apply(candidate)
        try existing.update(db)
        return existing.item
      }
      let minimum =
        try Int64.fetchOne(
          db,
          sql: "SELECT MIN(orderValue) FROM books"
        ) ?? 0
      var record = BookRecord(
        bookID: UUID().uuidString.lowercased(),
        candidate: candidate,
        membership: .staged,
        orderValue: minimum - 1,
        chapterCount: 0
      )
      try record.insert(db)
      return record.item
    }
  }

  public func add(
    _ candidate: ShelfBookCandidate,
    groupID: Int
  ) async throws -> ShelfBookItem {
    try await database.write { db in
      var record =
        try BookRecord
          .filter(Column("bookURL") == candidate.bookURL)
          .fetchOne(db)
        ?? BookRecord(
          bookID: UUID().uuidString.lowercased(),
          candidate: candidate,
          membership: .member(groupID: groupID),
          orderValue:
            (try Int64.fetchOne(
              db,
              sql: "SELECT MIN(orderValue) FROM books"
            ) ?? 0) - 1,
          chapterCount: 0
        )
      record.apply(candidate)
      record.inBookshelf = true
      record.groupID = max(0, groupID)
      try record.save(db)
      return record.item
    }
  }

  public func remove(
    bookID: LibraryDomain.BookID
  ) async throws {
    try await database.write { db in
      try db.execute(
        sql: """
          UPDATE books
          SET inBookshelf = 0, groupID = 0
          WHERE bookID = ?
          """,
        arguments: [bookID.rawValue]
      )
    }
  }

  public func shelfBooks() async throws -> [ShelfBookItem] {
    try await database.read { db in
      try BookRecord
        .filter(Column("inBookshelf") == true)
        .order(Column("orderValue").asc)
        .fetchAll(db)
        .map(\.item)
    }
  }

  public func book(
    forURL bookURL: String
  ) async throws -> ShelfBookItem? {
    try await database.read { db in
      try BookRecord
        .filter(Column("bookURL") == bookURL)
        .fetchOne(db)?
        .item
    }
  }

  public func reset() async throws {
    try await database.write { db in
      _ = try BookRecord.deleteAll(db)
    }
  }

  private static var migrator: DatabaseMigrator {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("createBooks") { db in
      try db.create(table: "books") { table in
        table.column("bookID", .text).primaryKey()
        table.column("bookURL", .text).notNull().unique()
        table.column("name", .text).notNull()
        table.column("author", .text).notNull()
        table.column("kind", .text).notNull()
        table.column("lastChapter", .text).notNull()
        table.column("intro", .text).notNull()
        table.column("coverURL", .text)
        table.column("originName", .text).notNull()
        table.column("inBookshelf", .boolean).notNull()
        table.column("groupID", .integer).notNull()
        table.column("orderValue", .integer).notNull()
        table.column("chapterCount", .integer).notNull()
      }
    }
    return migrator
  }
}

private struct BookRecord:
  Codable, FetchableRecord, MutablePersistableRecord
{
  static let databaseTableName = "books"

  var bookID: String
  var bookURL: String
  var name: String
  var author: String
  var kind: String
  var lastChapter: String
  var intro: String
  var coverURL: String?
  var originName: String
  var inBookshelf: Bool
  var groupID: Int
  var orderValue: Int64
  var chapterCount: Int

  init(
    bookID: String,
    candidate: ShelfBookCandidate,
    membership: ShelfMembership,
    orderValue: Int64,
    chapterCount: Int
  ) {
    self.bookID = bookID
    self.bookURL = candidate.bookURL
    self.name = candidate.name
    self.author = candidate.author
    self.kind = candidate.kind
    self.lastChapter = candidate.lastChapter
    self.intro = candidate.intro
    self.coverURL = candidate.coverURL
    self.originName = candidate.originName
    self.inBookshelf = membership.isInBookshelf
    self.groupID = membership.groupID
    self.orderValue = orderValue
    self.chapterCount = chapterCount
  }

  mutating func apply(_ candidate: ShelfBookCandidate) {
    bookURL = candidate.bookURL
    name = candidate.name
    author = candidate.author
    kind = candidate.kind
    lastChapter = candidate.lastChapter
    intro = candidate.intro
    coverURL = candidate.coverURL
    originName = candidate.originName
  }

  var item: ShelfBookItem {
    ShelfBookItem(
      id: LibraryDomain.BookID(rawValue: bookID),
      candidate: ShelfBookCandidate(
        name: name,
        author: author,
        kind: kind,
        lastChapter: lastChapter,
        intro: intro,
        bookURL: bookURL,
        coverURL: coverURL,
        originName: originName
      ),
      membership: inBookshelf
        ? .member(groupID: groupID)
        : .staged,
      order: orderValue,
      chapterCount: chapterCount
    )
  }
}
