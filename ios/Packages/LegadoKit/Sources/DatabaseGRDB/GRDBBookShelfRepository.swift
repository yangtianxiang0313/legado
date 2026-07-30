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

  public func book(
    id: LibraryDomain.BookID
  ) async throws -> ShelfBookItem? {
    try await database.read { db in
      try BookRecord
        .filter(Column("bookID") == id.rawValue)
        .fetchOne(db)?
        .item
    }
  }

  public func chapters(
    bookID: LibraryDomain.BookID
  ) async throws -> [LibraryDomain.BookChapter] {
    try await database.read { db in
      try ChapterRecord
        .filter(Column("bookID") == bookID.rawValue)
        .order(Column("chapterIndex").asc)
        .fetchAll(db)
        .map(\.chapter)
    }
  }

  public func applyTOCUpdate(
    bookID: LibraryDomain.BookID,
    update: LibraryDomain.ChapterTOCUpdate
  ) async throws -> [LibraryDomain.BookChapter] {
    try await database.write { db in
      switch update {
      case .replaced(_, let chapters):
        _ = try ChapterRecord
          .filter(Column("bookID") == bookID.rawValue)
          .deleteAll(db)
        for chapter in chapters {
          var record = ChapterRecord(chapter: chapter)
          try record.insert(db)
        }
        try db.execute(
          sql: """
            UPDATE books
            SET chapterCount = ?, updateError = 0
            WHERE bookID = ?
            """,
          arguments: [chapters.count, bookID.rawValue]
        )
      case .preserved:
        try db.execute(
          sql: "UPDATE books SET updateError = 1 WHERE bookID = ?",
          arguments: [bookID.rawValue]
        )
      }
      return try ChapterRecord
        .filter(Column("bookID") == bookID.rawValue)
        .order(Column("chapterIndex").asc)
        .fetchAll(db)
        .map(\.chapter)
    }
  }

  public func reset() async throws {
    try await database.write { db in
      _ = try ChapterRecord.deleteAll(db)
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
    migrator.registerMigration("addChapterTOCStorage") { db in
      try db.alter(table: "books") { table in
        table.add(
          column: "sourceID",
          .text
        ).notNull().defaults(to: "")
        table.add(
          column: "updateError",
          .boolean
        ).notNull().defaults(to: false)
      }
      try db.create(table: "chapters") { table in
        table.column("chapterID", .text).primaryKey()
        table.column("bookID", .text).notNull().indexed()
        table.column("sourceID", .text).notNull()
        table.column("chapterIndex", .integer).notNull()
        table.column("title", .text).notNull()
        table.column("url", .text).notNull()
        table.column("isPay", .boolean).notNull()
        table.column("isVIP", .boolean).notNull()
        table.column("isVolume", .boolean).notNull()
        table.foreignKey(
          ["bookID"],
          references: "books",
          columns: ["bookID"],
          onDelete: .cascade
        )
        table.uniqueKey(["bookID", "chapterIndex"])
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
  var sourceID: String
  var inBookshelf: Bool
  var groupID: Int
  var orderValue: Int64
  var chapterCount: Int
  var updateError: Bool

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
    self.sourceID = candidate.sourceID
    self.inBookshelf = membership.isInBookshelf
    self.groupID = membership.groupID
    self.orderValue = orderValue
    self.chapterCount = chapterCount
    self.updateError = false
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
    sourceID = candidate.sourceID
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
        originName: originName,
        sourceID: sourceID
      ),
      membership: inBookshelf
        ? .member(groupID: groupID)
        : .staged,
      order: orderValue,
      chapterCount: chapterCount
    )
  }
}

private struct ChapterRecord:
  Codable, FetchableRecord, MutablePersistableRecord
{
  static let databaseTableName = "chapters"

  var chapterID: String
  var bookID: String
  var sourceID: String
  var chapterIndex: Int
  var title: String
  var url: String
  var isPay: Bool
  var isVIP: Bool
  var isVolume: Bool

  init(chapter: LibraryDomain.BookChapter) {
    chapterID = chapter.id.rawValue
    bookID = chapter.bookID.rawValue
    sourceID = chapter.sourceID
    chapterIndex = chapter.index
    title = chapter.title
    url = chapter.url
    isPay = chapter.isPay
    isVIP = chapter.isVIP
    isVolume = chapter.isVolume
  }

  var chapter: LibraryDomain.BookChapter {
    LibraryDomain.BookChapter(
      id: LibraryDomain.ChapterID(rawValue: chapterID),
      bookID: LibraryDomain.BookID(rawValue: bookID),
      sourceID: sourceID,
      index: chapterIndex,
      title: title,
      url: url,
      isPay: isPay,
      isVIP: isVIP,
      isVolume: isVolume
    )
  }
}
