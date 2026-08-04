import AppUseCases
import BackupInteropUseCases
import Foundation
import GRDB
import LibraryDomain

public actor GRDBBookShelfRepository:
  BookShelfRepository, RuleSubscriptionRepository, RSSRepository,
  HTTPTextToSpeechRepository, DictionaryRuleRepository,
  KeyboardAssistRepository, AppThemeProfileRepository,
  DirectLinkUploadRuleRepository,
  WebDAVServerProfileRepository
{
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

  public func shelfGroups() async throws -> [ShelfGroupItem] {
    try await database.read { db in
      try AndroidLibraryGroupRecord
        .order(Column("orderValue").asc, Column("groupID").asc)
        .fetchAll(db)
        .compactMap { record in
          guard let groupID = Int(exactly: record.groupID), groupID > 0 else {
            return nil
          }
          return ShelfGroupItem(
            id: groupID,
            name: record.name,
            order: record.orderValue,
            isShown: record.isShown
          )
        }
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

  public func updateBookInfo(
    bookID: LibraryDomain.BookID,
    candidate: ShelfBookCandidate
  ) async throws -> ShelfBookItem {
    try await database.write { db in
      guard var record = try BookRecord
        .filter(Column("bookID") == bookID.rawValue)
        .fetchOne(db)
      else {
        throw ShelfMutationFailure.missingBook
      }
      record.apply(candidate)
      try record.update(db)
      return record.item
    }
  }

  public func updateBookMetadata(
    bookID: LibraryDomain.BookID,
    update: BookMetadataUpdate
  ) async throws -> ShelfBookItem {
    try await database.write { db in
      guard var record = try BookRecord
        .filter(Column("bookID") == bookID.rawValue)
        .fetchOne(db)
      else {
        throw ShelfMutationFailure.missingBook
      }
      record.name = update.name
      record.author = update.author
      record.customCoverURL =
        update.coverURL == record.coverURL
        ? nil
        : update.coverURL
      record.customIntro = update.intro
      try record.update(db)
      return record.item
    }
  }

  public func updateWebDAVBookState(
    bookID: LibraryDomain.BookID,
    sourceID: String,
    lastCheckTime: Int64
  ) async throws -> ShelfBookItem {
    try await database.write { db in
      guard var record = try BookRecord
        .filter(Column("bookID") == bookID.rawValue)
        .fetchOne(db)
      else {
        throw ShelfMutationFailure.missingBook
      }
      record.sourceID = sourceID
      record.lastCheckTime = max(0, lastCheckTime)
      try record.update(db)
      return record.item
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
    update: LibraryDomain.ChapterTOCUpdate,
    bookVariables: [String: String]?,
    tocURL: String?
  ) async throws -> [LibraryDomain.BookChapter] {
    try await database.write { db in
      if let bookVariables {
        try db.execute(
          sql: "UPDATE books SET variablesJSON = ? WHERE bookID = ?",
          arguments: [
            SourceVariableJSON.encode(bookVariables),
            bookID.rawValue,
          ]
        )
      }
      if let tocURL {
        try db.execute(
          sql: "UPDATE books SET tocURL = ? WHERE bookID = ?",
          arguments: [tocURL, bookID.rawValue]
        )
      }
      switch update {
      case .replaced(_, let chapters):
        guard var book = try BookRecord
          .filter(Column("bookID") == bookID.rawValue)
          .fetchOne(db)
        else {
          throw ShelfMutationFailure.missingBook
        }
        var status = ShelfChapterStatus(
          totalChapterCount: book.chapterCount,
          currentChapterIndex: book.progressChapterIndex ?? 0,
          latestCheckCount: book.latestCheckCount,
          latestChapterTime: book.latestChapterTime,
          lastReadTime: book.progressUpdatedAt ?? 0
        )
        _ = status.observeTOC(
          chapterCount: chapters.count,
          at: Int64(Date().timeIntervalSince1970 * 1_000)
        )
        _ = try ChapterRecord
          .filter(Column("bookID") == bookID.rawValue)
          .deleteAll(db)
        for chapter in chapters {
          var record = ChapterRecord(chapter: chapter)
          try record.insert(db)
        }
        book.chapterCount = status.totalChapterCount
        book.latestCheckCount = status.latestCheckCount
        book.latestChapterTime = status.latestChapterTime
        book.lastChapter = chapters.last?.title ?? book.lastChapter
        book.updateError = false
        try book.update(db)
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

  public func saveReadingProgress(
    bookID: LibraryDomain.BookID,
    progress: ReadingProgress
  ) async throws {
    try await database.write { db in
      try db.execute(
        sql: """
          UPDATE books
          SET progressChapterIndex = ?,
              progressCharacterOffset = ?,
              progressChapterTitle = ?,
              progressUpdatedAt = ?,
              latestCheckCount = 0
          WHERE bookID = ?
          """,
        arguments: [
          progress.position.chapterIndex,
          progress.position.characterOffset,
          progress.chapterTitle,
          progress.updatedAtMilliseconds,
          bookID.rawValue,
        ]
      )
    }
  }

  public func setReversesTableOfContents(
    bookID: LibraryDomain.BookID,
    enabled: Bool
  ) async throws -> ShelfBookItem {
    try await database.write { db in
      guard var book = try BookRecord
        .filter(Column("bookID") == bookID.rawValue)
        .fetchOne(db)
      else {
        throw ShelfMutationFailure.missingBook
      }
      guard book.reversesTableOfContents != enabled else {
        return book.item
      }
      var records = try ChapterRecord
        .filter(Column("bookID") == bookID.rawValue)
        .order(Column("chapterIndex").asc)
        .fetchAll(db)
      let currentChapterID = records.first(where: {
        $0.chapterIndex == book.progressChapterIndex
      })?.chapterID
      records.reverse()
      for index in records.indices {
        records[index].chapterIndex = -(index + 1)
        try records[index].update(db)
      }
      for index in records.indices {
        records[index].chapterIndex = index
        try records[index].update(db)
      }
      book.reversesTableOfContents = enabled
      if
        let currentChapterID,
        let remappedIndex = records.firstIndex(where: {
          $0.chapterID == currentChapterID
        })
      {
        book.progressChapterIndex = remappedIndex
      }
      try book.update(db)
      return book.item
    }
  }

  public func setBookTTSEngine(
    bookID: LibraryDomain.BookID,
    value: String?
  ) async throws -> ShelfBookItem {
    try await database.write { db in
      guard var book = try BookRecord
        .filter(Column("bookID") == bookID.rawValue)
        .fetchOne(db)
      else {
        throw ShelfMutationFailure.missingBook
      }
      book.ttsEngine = value
      try book.update(db)
      return book.item
    }
  }

  public func setBookImageStyle(
    bookID: LibraryDomain.BookID,
    value: String?
  ) async throws -> ShelfBookItem {
    try await database.write { db in
      guard var book = try BookRecord
        .filter(Column("bookID") == bookID.rawValue)
        .fetchOne(db)
      else {
        throw ShelfMutationFailure.missingBook
      }
      book.imageStyle = value
      try book.update(db)
      return book.item
    }
  }

  public func applySourceSwitch(
    bookID: LibraryDomain.BookID,
    candidate: ShelfBookCandidate,
    chapters: [LibraryDomain.BookChapter],
    progress: ReadingProgress,
    persist: Bool
  ) async throws -> ShelfBookItem {
    try await database.write { db in
      guard var record = try BookRecord
        .filter(Column("bookID") == bookID.rawValue)
        .fetchOne(db)
      else {
        throw BookSourceSwitchFailure.missingBook
      }
      let membership: ShelfMembership = record.inBookshelf
        ? .member(groupID: record.groupID)
        : .staged
      let order = record.orderValue
      if !persist {
        _ = try BookRecord
          .filter(Column("bookID") == bookID.rawValue)
          .deleteAll(db)
        return ShelfBookItem(
          id: bookID,
          candidate: candidate,
          membership: .staged,
          order: order,
          chapterCount: chapters.count,
          progress: progress,
          reversesTableOfContents: record.reversesTableOfContents,
          splitsLongChapters: record.splitsLongChapters,
          usesReplacementRules: record.usesReplacementRules,
          ttsEngine: record.ttsEngine,
          imageStyle: record.imageStyle
        )
      }

      record.apply(candidate)
      record.chapterCount = chapters.count
      record.updateError = false
      record.progressChapterIndex = progress.position.chapterIndex
      record.progressCharacterOffset =
        progress.position.characterOffset
      record.progressChapterTitle = progress.chapterTitle
      record.progressUpdatedAt = progress.updatedAtMilliseconds
      record.latestCheckCount = 0
      try record.update(db)
      _ = try ChapterRecord
        .filter(Column("bookID") == bookID.rawValue)
        .deleteAll(db)
      for chapter in chapters {
        var chapterRecord = ChapterRecord(chapter: chapter)
        try chapterRecord.insert(db)
      }
      var item = record.item
      if item.membership != membership {
        item = ShelfBookItem(
          id: item.id,
          candidate: item.candidate,
          membership: membership,
          order: item.order,
          chapterCount: item.chapterCount,
          progress: item.progress,
          latestChapterTime: item.latestChapterTime,
          lastCheckTime: item.lastCheckTime,
          latestCheckCount: item.latestCheckCount,
          canUpdate: item.canUpdate,
          reversesTableOfContents: item.reversesTableOfContents,
          splitsLongChapters: item.splitsLongChapters,
          usesReplacementRules: item.usesReplacementRules,
          ttsEngine: item.ttsEngine,
          imageStyle: item.imageStyle
        )
      }
      return item
    }
  }

  public func shelfSortMode(
    groupID: Int?
  ) async throws -> ShelfSortMode {
    try await database.read { db in
      let global = try Int.fetchOne(
        db,
        sql: "SELECT sortMode FROM shelfPreferences WHERE groupID = -1"
      ) ?? ShelfSortMode.recentlyRead.rawValue
      let rawValue: Int
      if let groupID {
        rawValue = try Int.fetchOne(
          db,
          sql: """
            SELECT sortMode FROM shelfPreferences WHERE groupID = ?
            """,
          arguments: [groupID]
        ) ?? global
      } else {
        rawValue = global
      }
      return ShelfSortMode(rawValue: rawValue) ?? .recentlyRead
    }
  }

  public func setShelfSortMode(
    _ mode: ShelfSortMode,
    groupID: Int?
  ) async throws {
    try await database.write { db in
      try db.execute(
        sql: """
          INSERT INTO shelfPreferences (groupID, sortMode)
          VALUES (?, ?)
          ON CONFLICT(groupID) DO UPDATE SET sortMode = excluded.sortMode
          """,
        arguments: [groupID ?? -1, mode.rawValue]
      )
    }
  }

  public func applyShelfMutation(
    _ mutation: ShelfBatchMutation,
    bookID: LibraryDomain.BookID
  ) async throws {
    try await database.write { db in
      let exists = try Bool.fetchOne(
        db,
        sql: "SELECT EXISTS(SELECT 1 FROM books WHERE bookID = ?)",
        arguments: [bookID.rawValue]
      ) ?? false
      guard exists else {
        throw ShelfMutationFailure.missingBook
      }
      switch mutation {
      case .delete:
        _ = try BookRecord
          .filter(Column("bookID") == bookID.rawValue)
          .deleteAll(db)
      case .clearCache:
        _ = try ChapterContentRecord
          .filter(Column("bookID") == bookID.rawValue)
          .deleteAll(db)
      case .setCanUpdate(let canUpdate):
        try db.execute(
          sql: """
            UPDATE books
            SET canUpdate = ?,
                updateError = CASE WHEN ? THEN updateError ELSE 0 END
            WHERE bookID = ?
            """,
          arguments: [canUpdate, canUpdate, bookID.rawValue]
        )
      case .moveToGroup(let groupID):
        try db.execute(
          sql: "UPDATE books SET groupID = ? WHERE bookID = ?",
          arguments: [max(0, groupID), bookID.rawValue]
        )
      }
    }
  }

  public func setShelfOrder(
    _ bookIDs: [LibraryDomain.BookID]
  ) async throws {
    try await database.write { db in
      for (index, bookID) in bookIDs.enumerated() {
        try db.execute(
          sql: "UPDATE books SET orderValue = ? WHERE bookID = ?",
          arguments: [index, bookID.rawValue]
        )
      }
    }
  }

  public func webDAVServerProfiles() async throws -> [WebDAVServerProfile] {
    try await database.read { db in
      try WebDAVServerProfileRecord
        .order(Column("sortNumber").asc, Column("id").asc)
        .fetchAll(db)
        .map(\.value)
    }
  }

  public func selectedWebDAVServerProfileID() async throws -> Int64? {
    try await database.read { db in
      try Int64.fetchOne(
        db,
        sql: "SELECT selectedID FROM webDAVServerSelection WHERE singleton = 0"
      )
    }
  }

  public func replaceWebDAVServerProfiles(
    _ profiles: [WebDAVServerProfile],
    selectedID: Int64?
  ) async throws {
    try await database.write { db in
      _ = try WebDAVServerProfileRecord
        .filter(Column("id") != WebDAVServerProfile.androidDefaultID)
        .deleteAll(db)
      for profile in profiles {
        var record = WebDAVServerProfileRecord(value: profile)
        try record.insert(db)
      }
      try db.execute(
        sql: "DELETE FROM webDAVServerSelection WHERE singleton = 0"
      )
      if let selectedID {
        try db.execute(
          sql: "INSERT INTO webDAVServerSelection (singleton, selectedID) VALUES (0, ?)",
          arguments: [selectedID]
        )
      }
    }
  }

  public func upsertWebDAVServerProfile(
    _ profile: WebDAVServerProfile
  ) async throws {
    try await database.write { db in
      var record = WebDAVServerProfileRecord(value: profile)
      try record.save(db)
    }
  }

  public func deleteWebDAVServerProfile(id: Int64) async throws {
    try await database.write { db in
      _ = try WebDAVServerProfileRecord.deleteOne(db, key: id)
    }
  }

  public func selectWebDAVServerProfile(id: Int64?) async throws {
    try await database.write { db in
      try db.execute(
        sql: "DELETE FROM webDAVServerSelection WHERE singleton = 0"
      )
      if let id {
        try db.execute(
          sql: "INSERT INTO webDAVServerSelection (singleton, selectedID) VALUES (0, ?)",
          arguments: [id]
        )
      }
    }
  }

  public func importLocalText(
    candidate: ShelfBookCandidate,
    chapters: [LocalTextChapter]
  ) async throws -> ShelfBookItem {
    try await database.write { db in
      var record =
        try BookRecord
          .filter(Column("bookURL") == candidate.bookURL)
          .fetchOne(db)
        ?? BookRecord(
          bookID: UUID().uuidString.lowercased(),
          candidate: candidate,
          membership: .member(groupID: 0),
          orderValue:
            (try Int64.fetchOne(
              db,
              sql: "SELECT MIN(orderValue) FROM books"
            ) ?? 0) - 1,
          chapterCount: 0
        )
      record.apply(candidate)
      record.inBookshelf = true
      record.chapterCount = chapters.count
      record.lastChapter = chapters.last?.title ?? ""
      record.updateError = false
      record.latestCheckCount = 0
      try record.save(db)

      _ = try ChapterRecord
        .filter(Column("bookID") == record.bookID)
        .deleteAll(db)
      _ = try ChapterContentRecord
        .filter(Column("bookID") == record.bookID)
        .deleteAll(db)
      for (index, chapter) in chapters.enumerated() {
        let chapterURL = "\(candidate.bookURL)#chapter-\(index)"
        let value = LibraryDomain.BookChapter(
          id: LibraryDomain.ChapterID(
            sourceID: "local-file",
            chapterURL: chapterURL
          ),
          bookID: LibraryDomain.BookID(rawValue: record.bookID),
          sourceID: "local-file",
          index: index,
          title: chapter.title,
          url: chapterURL
        )
        var chapterRecord = ChapterRecord(chapter: value)
        try chapterRecord.insert(db)
        var contentRecord = ChapterContentRecord(
          bookID: record.bookID,
          chapterID: value.id.rawValue,
          content: chapter.content
        )
        try contentRecord.insert(db)
      }
      return record.item
    }
  }

  public func rebuildLocalText(
    bookID: LibraryDomain.BookID,
    chapters: [LocalTextChapter],
    splitsLongChapters: Bool
  ) async throws -> ShelfBookItem {
    try await rebuildLocalText(
      bookID: bookID,
      chapters: chapters,
      splitsLongChapters: splitsLongChapters,
      managedReference: nil
    )
  }

  public func rebuildLocalText(
    bookID: LibraryDomain.BookID,
    chapters: [LocalTextChapter],
    splitsLongChapters: Bool,
    managedReference: String?
  ) async throws -> ShelfBookItem {
    try await database.write { db in
      guard
        var record = try BookRecord
          .filter(Column("bookID") == bookID.rawValue)
          .fetchOne(db),
        AndroidWebDAVBookOrigin.isLocalSource(record.sourceID)
      else {
        throw ShelfMutationFailure.missingBook
      }
      let previousChapters = try ChapterRecord
        .filter(Column("bookID") == record.bookID)
        .order(Column("chapterIndex").asc)
        .fetchAll(db)
      let previousContents = Dictionary(
        uniqueKeysWithValues: try ChapterContentRecord
          .filter(Column("bookID") == record.bookID)
          .fetchAll(db)
          .map { ($0.chapterID, $0.content) }
      )
      record.splitsLongChapters = splitsLongChapters
      if let managedReference {
        record.bookURL = managedReference
        record.bookRequestExpression = managedReference
      }
      record.chapterCount = chapters.count
      record.lastChapter = chapters.last?.title ?? ""
      record.updateError = false
      if
        let progressIndex = record.progressChapterIndex,
        !chapters.isEmpty
      {
        let oldIndex = min(
          max(0, progressIndex),
          max(0, previousChapters.count - 1)
        )
        let oldChapter = previousChapters.indices.contains(oldIndex)
          ? previousChapters[oldIndex]
          : nil
        let baseTitle = localTextBaseTitle(
          oldChapter?.title
            ?? record.progressChapterTitle
            ?? ""
        )
        let oldSiblings = previousChapters.filter {
          localTextBaseTitle($0.title) == baseTitle
        }
        var absoluteOffset = max(
          0,
          record.progressCharacterOffset ?? 0
        )
        for sibling in oldSiblings {
          guard sibling.chapterIndex < oldIndex else { break }
          absoluteOffset += previousContents[
            sibling.chapterID
          ]?.count ?? 0
        }
        let newSiblings = chapters.enumerated().filter {
          localTextBaseTitle($0.element.title) == baseTitle
        }
        var mappedIndex = min(oldIndex, chapters.count - 1)
        var mappedOffset = 0
        if !newSiblings.isEmpty {
          var remaining = absoluteOffset
          for (position, sibling) in newSiblings {
            mappedIndex = position
            mappedOffset = min(remaining, sibling.content.count)
            if remaining <= sibling.content.count {
              break
            }
            remaining -= sibling.content.count
          }
        }
        record.progressChapterIndex = mappedIndex
        record.progressCharacterOffset = mappedOffset
        record.progressChapterTitle = chapters[mappedIndex].title
      }
      try record.update(db)

      _ = try ChapterRecord
        .filter(Column("bookID") == record.bookID)
        .deleteAll(db)
      _ = try ChapterContentRecord
        .filter(Column("bookID") == record.bookID)
        .deleteAll(db)
      for (index, chapter) in chapters.enumerated() {
        let chapterURL = "\(record.bookURL)#chapter-\(index)"
        let value = LibraryDomain.BookChapter(
          id: LibraryDomain.ChapterID(
            sourceID: "local-file",
            chapterURL: chapterURL
          ),
          bookID: bookID,
          sourceID: "local-file",
          index: index,
          title: chapter.title,
          url: chapterURL
        )
        var chapterRecord = ChapterRecord(chapter: value)
        try chapterRecord.insert(db)
        var contentRecord = ChapterContentRecord(
          bookID: record.bookID,
          chapterID: value.id.rawValue,
          content: chapter.content
        )
        try contentRecord.insert(db)
      }
      return record.item
    }
  }

  public func chapterContent(
    bookID: LibraryDomain.BookID,
    chapterID: LibraryDomain.ChapterID
  ) async throws -> String? {
    try await database.read { db in
      try ChapterContentRecord
        .filter(Column("bookID") == bookID.rawValue)
        .filter(Column("chapterID") == chapterID.rawValue)
        .fetchOne(db)?
        .content
    }
  }

  public func saveChapterContent(
    _ content: String,
    bookID: LibraryDomain.BookID,
    chapterID: LibraryDomain.ChapterID
  ) async throws {
    guard !content.isEmpty else { return }
    try await database.write { db in
      let chapterExists = try Bool.fetchOne(
        db,
        sql: """
          SELECT EXISTS(
            SELECT 1 FROM chapters
            WHERE bookID = ? AND chapterID = ?
          )
          """,
        arguments: [bookID.rawValue, chapterID.rawValue]
      ) ?? false
      guard chapterExists else {
        throw ShelfMutationFailure.missingBook
      }
      var record = ChapterContentRecord(
        bookID: bookID.rawValue,
        chapterID: chapterID.rawValue,
        content: content
      )
      try record.save(db)
    }
  }

  public func saveSourceChapterTitle(
    _ title: String,
    bookID: LibraryDomain.BookID,
    chapterID: LibraryDomain.ChapterID
  ) async throws {
    guard !title.isEmpty else { return }
    try await database.write { db in
      try db.execute(
        sql: """
          UPDATE chapters
          SET title = ?
          WHERE bookID = ? AND chapterID = ?
          """,
        arguments: [title, bookID.rawValue, chapterID.rawValue]
      )
    }
  }

  public func clearChapterContents(
    bookID: LibraryDomain.BookID,
    chapterIDs: [LibraryDomain.ChapterID]
  ) async throws {
    guard !chapterIDs.isEmpty else { return }
    let rawIDs = chapterIDs.map(\.rawValue)
    try await database.write { db in
      _ = try ChapterContentRecord
        .filter(Column("bookID") == bookID.rawValue)
        .filter(rawIDs.contains(Column("chapterID")))
        .deleteAll(db)
    }
  }

  public func saveSourceVariables(
    bookID: LibraryDomain.BookID,
    bookVariables: [String: String]?,
    chapterID: LibraryDomain.ChapterID?,
    chapterVariables: [String: String]?
  ) async throws {
    try await database.write { db in
      if let bookVariables {
        try db.execute(
          sql: "UPDATE books SET variablesJSON = ? WHERE bookID = ?",
          arguments: [
            SourceVariableJSON.encode(bookVariables),
            bookID.rawValue,
          ]
        )
      }
      if let chapterID, let chapterVariables {
        try db.execute(
          sql: """
            UPDATE chapters
            SET variablesJSON = ?
            WHERE bookID = ? AND chapterID = ?
            """,
          arguments: [
            SourceVariableJSON.encode(chapterVariables),
            bookID.rawValue,
            chapterID.rawValue,
          ]
        )
      }
    }
  }

  public func bookmarks(
    bookID: LibraryDomain.BookID
  ) async throws -> [ReadingBookmark] {
    try await database.read { db in
      let native = try ReadingBookmarkRecord
        .filter(Column("bookID") == bookID.rawValue)
        .fetchAll(db)
        .map(\.bookmark)
      guard let book = try BookRecord.fetchOne(db, key: bookID.rawValue)
      else { return native }
      let chapters = try ChapterRecord
        .filter(Column("bookID") == bookID.rawValue)
        .order(Column("chapterIndex").asc, Column("chapterID").asc)
        .fetchAll(db)
      let chapterByIndex = Dictionary(
        chapters.map { ($0.chapterIndex, $0) },
        uniquingKeysWith: { first, _ in first }
      )
      let restored = try AndroidLibraryBookmarkRecord
        .filter(
          Column("bookName") == book.name
            && Column("bookAuthor") == book.author
        )
        .fetchAll(db)
        .compactMap { record -> ReadingBookmark? in
          guard let chapter = chapterByIndex[record.chapterIndex]
          else { return nil }
          return Self.projectRestoredBookmark(
            record,
            bookID: bookID,
            chapter: chapter
          )
        }
      var merged = Dictionary(
        restored.map { ($0.id, $0) },
        uniquingKeysWith: { first, _ in first }
      )
      // Native iOS edits own the presentation when both platforms describe
      // the same chapter position. The Android row remains available for
      // lossless backup export until that position is explicitly removed.
      for bookmark in native {
        merged[bookmark.id] = bookmark
      }
      return merged.values.sorted {
        if $0.chapterIndex != $1.chapterIndex {
          return $0.chapterIndex < $1.chapterIndex
        }
        if $0.characterOffset != $1.characterOffset {
          return $0.characterOffset < $1.characterOffset
        }
        return $0.createdAtMilliseconds < $1.createdAtMilliseconds
      }
    }
  }

  public func saveBookmark(
    _ bookmark: ReadingBookmark
  ) async throws {
    try await database.write { db in
      var record = ReadingBookmarkRecord(bookmark: bookmark)
      try record.save(db)
    }
  }

  public func deleteBookmark(id: String) async throws {
    try await database.write { db in
      _ = try ReadingBookmarkRecord
        .filter(Column("bookmarkID") == id)
        .deleteAll(db)
      let books = try BookRecord.fetchAll(db)
      for book in books {
        let bookID = LibraryDomain.BookID(rawValue: book.bookID)
        let chapters = try ChapterRecord
          .filter(Column("bookID") == book.bookID)
          .fetchAll(db)
        let chapterByIndex = Dictionary(
          chapters.map { ($0.chapterIndex, $0) },
          uniquingKeysWith: { first, _ in first }
        )
        let restored = try AndroidLibraryBookmarkRecord
          .filter(
            Column("bookName") == book.name
              && Column("bookAuthor") == book.author
          )
          .fetchAll(db)
        for record in restored {
          guard
            let chapter = chapterByIndex[record.chapterIndex],
            Self.projectRestoredBookmark(
              record,
              bookID: bookID,
              chapter: chapter
            ).id == id
          else { continue }
          _ = try AndroidLibraryBookmarkRecord
            .filter(Column("time") == record.time)
            .deleteAll(db)
        }
      }
    }
  }

  private static func projectRestoredBookmark(
    _ record: AndroidLibraryBookmarkRecord,
    bookID: LibraryDomain.BookID,
    chapter: ChapterRecord
  ) -> ReadingBookmark {
    let chapterID = LibraryDomain.ChapterID(rawValue: chapter.chapterID)
    return ReadingBookmark(
      id: ReadingBookmark.stableID(
        bookID: bookID,
        chapterID: chapterID,
        characterOffset: record.chapterPosition
      ),
      bookID: bookID,
      chapterID: chapterID,
      chapterIndex: record.chapterIndex,
      characterOffset: record.chapterPosition,
      chapterTitle: record.chapterName.isEmpty
        ? chapter.title
        : record.chapterName,
      excerpt: record.content.isEmpty ? record.bookText : record.content,
      createdAtMilliseconds: record.time
    )
  }

  public func replacementRules() async throws -> [ReaderReplacementRule] {
    try await database.read { db in
      try ReaderReplacementRuleRecord
        .order(Column("orderValue").asc, Column("name").asc)
        .fetchAll(db)
        .map(\.rule)
    }
  }

  public func saveReplacementRule(
    _ rule: ReaderReplacementRule
  ) async throws {
    try await database.write { db in
      var record = ReaderReplacementRuleRecord(rule: rule)
      try record.save(db)
    }
  }

  public func deleteReplacementRule(id: String) async throws {
    try await database.write { db in
      _ = try ReaderReplacementRuleRecord
        .filter(Column("ruleID") == id)
        .deleteAll(db)
    }
  }

  public func resetReplacementRules() async throws {
    try await database.write { db in
      _ = try ReaderReplacementRuleRecord.deleteAll(db)
    }
  }

  public func restoreAndroidLibrary(
    _ plan: AndroidLibraryRestorePlan
  ) async throws -> AndroidLibraryRestoreSummary {
    try await database.write { db in
      for value in plan.books {
        let groupMask = try Self.platformGroupMask(value.groupMask)
        var record =
          try BookRecord
            .filter(Column("bookURL") == value.candidate.bookURL)
            .fetchOne(db)
          ?? BookRecord(
            bookID: UUID().uuidString.lowercased(),
            candidate: value.candidate,
            membership: .member(groupID: groupMask),
            orderValue: value.order,
            chapterCount: value.chapterCount
          )
        record.apply(value.candidate)
        record.inBookshelf = true
        record.groupID = groupMask
        record.orderValue = value.order
        record.chapterCount = value.chapterCount
        record.progressChapterIndex = value.progress.position.chapterIndex
        record.progressCharacterOffset = value.progress.position.characterOffset
        record.progressChapterTitle = value.progress.chapterTitle
        record.progressUpdatedAt = value.progress.updatedAtMilliseconds
        record.latestChapterTime = value.latestChapterTime
        record.lastCheckTime = value.lastCheckTime
        record.latestCheckCount = value.latestCheckCount
        record.canUpdate = value.canUpdate
        record.reversesTableOfContents = value.reversesTableOfContents
        record.splitsLongChapters = value.splitsLongChapters
        record.usesReplacementRules = value.usesReplacementRules
        record.ttsEngine = value.ttsEngine
        record.imageStyle = value.imageStyle
        record.androidType = value.androidType
        record.originOrder = value.originOrder
        record.syncTime = value.syncTime
        record.charset = value.charset
        record.customTag = value.customTag
        record.wordCount = value.wordCount
        try record.save(db)
      }
      for value in plan.groups {
        var record = AndroidLibraryGroupRecord(value: value)
        try record.save(db)
      }
      for value in plan.bookmarks {
        var record = AndroidLibraryBookmarkRecord(value: value)
        try record.save(db)
      }
      return AndroidLibraryRestoreSummary(
        bookCount: plan.books.count,
        groupCount: plan.groups.count,
        bookmarkCount: plan.bookmarks.count
      )
    }
  }

  public func restoreAndroidDatabaseDomains(
    _ payload: AndroidCoreDatabaseRestorePayload
  ) async throws -> AndroidLibraryRestoreSummary {
    let encodedReaderStyles = try payload.readerConfigBundle.encodedStyles()
    let encodedSharedReaderStyle = try payload.readerConfigBundle
      .encodedSharedStyle()
    return try await database.write { db in
      for value in payload.library.books {
        let groupMask = try Self.platformGroupMask(value.groupMask)
        var record =
          try BookRecord
            .filter(Column("bookURL") == value.candidate.bookURL)
            .fetchOne(db)
          ?? BookRecord(
            bookID: UUID().uuidString.lowercased(),
            candidate: value.candidate,
            membership: .member(groupID: groupMask),
            orderValue: value.order,
            chapterCount: value.chapterCount
          )
        record.apply(value.candidate)
        record.inBookshelf = true
        record.groupID = groupMask
        record.orderValue = value.order
        record.chapterCount = value.chapterCount
        record.progressChapterIndex = value.progress.position.chapterIndex
        record.progressCharacterOffset = value.progress.position.characterOffset
        record.progressChapterTitle = value.progress.chapterTitle
        record.progressUpdatedAt = value.progress.updatedAtMilliseconds
        record.latestChapterTime = value.latestChapterTime
        record.lastCheckTime = value.lastCheckTime
        record.latestCheckCount = value.latestCheckCount
        record.canUpdate = value.canUpdate
        record.reversesTableOfContents = value.reversesTableOfContents
        record.splitsLongChapters = value.splitsLongChapters
        record.usesReplacementRules = value.usesReplacementRules
        record.ttsEngine = value.ttsEngine
        record.imageStyle = value.imageStyle
        record.androidType = value.androidType
        record.originOrder = value.originOrder
        record.syncTime = value.syncTime
        record.charset = value.charset
        record.customTag = value.customTag
        record.wordCount = value.wordCount
        try record.save(db)
      }
      for value in payload.library.groups {
        var record = AndroidLibraryGroupRecord(value: value)
        try record.save(db)
      }
      for value in payload.library.bookmarks {
        var record = AndroidLibraryBookmarkRecord(value: value)
        try record.save(db)
      }
      for value in payload.replacementRules {
        var record = ReaderReplacementRuleRecord(rule: value)
        try record.save(db)
      }
      for value in payload.readRecords {
        var record = ReadRecordRecord(value: value)
        try record.save(db)
      }
      for value in payload.searchHistory {
        var record = SearchHistoryRecord(value: value)
        try record.save(db)
      }
      for value in payload.ruleSubscriptions {
        var record = RuleSubscriptionRecord(value: value)
        try record.save(db)
      }
      for value in payload.rssSources {
        var record = try RSSSourceRecord(value: value)
        try record.save(db)
      }
      for value in payload.rssStars {
        var record = try RSSStarRecord(value: value)
        try record.save(db)
      }
      for value in payload.httpTextToSpeechEngines {
        var record = try HTTPTextToSpeechRecord(value: value)
        try record.save(db)
      }
      for value in payload.localTextTOCRules {
        var record = try LocalTextTOCRuleRecord(value: value)
        try record.save(db)
      }
      if !payload.readerConfigBundle.styles.isEmpty {
        var record = AndroidReaderConfigRecord(
          key: "styles",
          payload: encodedReaderStyles
        )
        try record.save(db)
      }
      if let encodedSharedReaderStyle {
        var record = AndroidReaderConfigRecord(
          key: "shared",
          payload: encodedSharedReaderStyle
        )
        try record.save(db)
      }
      for value in payload.dictionaryRules {
        var record = try DictionaryRuleRecord(value: value)
        try record.save(db)
      }
      for value in payload.keyboardAssists {
        var record = try KeyboardAssistRecord(value: value)
        try record.save(db)
      }
      for value in payload.themeProfiles {
        var record = try AppThemeProfileRecord(value: value)
        try record.save(db)
      }
      if let value = payload.directLinkUploadRule {
        var record = try DirectLinkUploadRuleRecord(value: value)
        try record.save(db)
      }
      if let mode = payload.globalShelfSortMode {
        try db.execute(
          sql: """
            INSERT INTO shelfPreferences (groupID, sortMode)
            VALUES (-1, ?)
            ON CONFLICT(groupID) DO UPDATE SET sortMode = excluded.sortMode
            """,
          arguments: [mode.rawValue]
        )
      }
      return AndroidLibraryRestoreSummary(
        bookCount: payload.library.books.count,
        groupCount: payload.library.groups.count,
        bookmarkCount: payload.library.bookmarks.count
      )
    }
  }

  public func restoredAndroidLibraryPlan() async throws
    -> AndroidLibraryRestorePlan
  {
    try await database.read { db in
      AndroidLibraryRestorePlan(
        books: try BookRecord
          .order(Column("orderValue").asc)
          .fetchAll(db)
          .map(\.androidRestoreValue),
        groups: try AndroidLibraryGroupRecord
          .order(Column("orderValue").asc)
          .fetchAll(db)
          .map(\.value),
        bookmarks: try AndroidLibraryBookmarkRecord
          .order(Column("time").asc)
          .fetchAll(db)
          .map(\.value)
      )
    }
  }

  public func androidLibraryBackupPlan() async throws
    -> AndroidLibraryRestorePlan
  {
    try await database.read { db in
      let books = try BookRecord
        .order(Column("orderValue").asc)
        .fetchAll(db)
      let groups = try AndroidLibraryGroupRecord
        .order(Column("orderValue").asc)
        .fetchAll(db)
        .map(\.value)
      var bookmarksByTime = Dictionary(
        uniqueKeysWithValues: try AndroidLibraryBookmarkRecord
          .fetchAll(db)
          .map(\.value)
          .map { ($0.time, $0) }
      )
      let booksByID = Dictionary(
        uniqueKeysWithValues: books.map { ($0.bookID, $0) }
      )
      for record in try ReadingBookmarkRecord.fetchAll(db) {
        guard let book = booksByID[record.bookID] else { continue }
        bookmarksByTime[record.createdAtMilliseconds] = Bookmark(
          time: record.createdAtMilliseconds,
          bookName: book.name,
          bookAuthor: book.author,
          chapterIndex: record.chapterIndex,
          chapterPosition: record.characterOffset,
          chapterName: record.chapterTitle,
          bookText: record.excerpt,
          content: record.excerpt
        )
      }
      return AndroidLibraryRestorePlan(
        books: books.map(\.androidRestoreValue),
        groups: groups,
        bookmarks: bookmarksByTime.values.sorted { $0.time < $1.time }
      )
    }
  }

  public func androidReadRecords() async throws -> [LibraryDomain.ReadRecord] {
    try await database.read { db in
      try ReadRecordRecord
        .order(Column("lastRead").asc)
        .fetchAll(db)
        .map(\.value)
    }
  }

  public func records(
    bookName: String
  ) async throws -> [LibraryDomain.ReadRecord] {
    try await database.read { db in
      try ReadRecordRecord
        .filter(Column("bookName") == bookName)
        .order(Column("deviceID").asc)
        .fetchAll(db)
        .map(\.value)
    }
  }

  public func upsert(
    _ value: LibraryDomain.ReadRecord
  ) async throws {
    try await database.write { db in
      var record = ReadRecordRecord(value: value)
      try record.save(db)
    }
  }

  public func searchHistory() async throws -> [SearchHistoryEntry] {
    try await database.read { db in
      try SearchHistoryRecord
        .order(Column("lastUseTime").desc)
        .fetchAll(db)
        .map(\.value)
    }
  }

  public func upsertSearchHistory(_ entry: SearchHistoryEntry) async throws {
    try await database.write { db in
      var record = SearchHistoryRecord(value: entry)
      try record.save(db)
    }
  }

  public func androidSearchHistory() async throws -> [SearchHistoryEntry] {
    try await searchHistory()
  }

  public func restoreAndroidSearchHistory(
    _ entries: [SearchHistoryEntry]
  ) async throws {
    try await database.write { db in
      for entry in entries {
        var record = SearchHistoryRecord(value: entry)
        try record.save(db)
      }
    }
  }

  public func ruleSubscriptions() async throws -> [RuleSubscription] {
    try await database.read { db in
      try RuleSubscriptionRecord
        .order(Column("customOrder").asc, Column("id").asc)
        .fetchAll(db)
        .map(\.value)
    }
  }

  public func upsertRuleSubscription(
    _ value: RuleSubscription
  ) async throws {
    try await database.write { db in
      var record = RuleSubscriptionRecord(value: value)
      try record.save(db)
    }
  }

  public func deleteRuleSubscription(id: Int64) async throws {
    try await database.write { db in
      _ = try RuleSubscriptionRecord
        .filter(Column("id") == id)
        .deleteAll(db)
    }
  }

  public func androidRuleSubscriptions() async throws -> [RuleSubscription] {
    try await ruleSubscriptions()
  }

  public func restoreAndroidRuleSubscriptions(
    _ values: [RuleSubscription]
  ) async throws {
    try await database.write { db in
      for value in values {
        var record = RuleSubscriptionRecord(value: value)
        try record.save(db)
      }
    }
  }

  public func rssSources() async throws -> [RSSSource] {
    try await database.read { db in
      try RSSSourceRecord
        .order(Column("customOrder").asc, Column("sourceURL").asc)
        .fetchAll(db)
        .map { try $0.value }
    }
  }

  public func rssStars() async throws -> [RSSStar] {
    try await database.read { db in
      try RSSStarRecord
        .order(Column("starTime").desc)
        .fetchAll(db)
        .map { try $0.value }
    }
  }

  public func upsertRSSSource(_ source: RSSSource) async throws {
    try await database.write { db in
      var record = try RSSSourceRecord(value: source)
      try record.save(db)
    }
  }

  public func upsertRSSStar(_ star: RSSStar) async throws {
    try await database.write { db in
      var record = try RSSStarRecord(value: star)
      try record.save(db)
    }
  }

  public func deleteRSSStar(origin: String, link: String) async throws {
    try await database.write { db in
      _ = try RSSStarRecord
        .filter(Column("origin") == origin && Column("link") == link)
        .deleteAll(db)
    }
  }

  public func androidRSSSources() async throws -> [RSSSource] {
    try await rssSources()
  }

  public func androidRSSStars() async throws -> [RSSStar] {
    try await rssStars()
  }

  public func restoreAndroidRSS(
    sources: [RSSSource],
    stars: [RSSStar]
  ) async throws {
    try await database.write { db in
      for source in sources {
        var record = try RSSSourceRecord(value: source)
        try record.save(db)
      }
      for star in stars {
        var record = try RSSStarRecord(value: star)
        try record.save(db)
      }
    }
  }

  public func httpTextToSpeechEngines() async throws
    -> [HTTPTextToSpeechEngine]
  {
    try await database.read { db in
      try HTTPTextToSpeechRecord
        .order(Column("name").asc, Column("id").asc)
        .fetchAll(db)
        .map { try $0.value }
    }
  }

  public func upsertHTTPTextToSpeechEngine(
    _ engine: HTTPTextToSpeechEngine
  ) async throws {
    try await database.write { db in
      var record = try HTTPTextToSpeechRecord(value: engine)
      try record.save(db)
    }
  }

  public func androidHTTPTextToSpeechEngines() async throws
    -> [HTTPTextToSpeechEngine]
  {
    try await httpTextToSpeechEngines()
  }

  public func restoreAndroidHTTPTextToSpeechEngines(
    _ values: [HTTPTextToSpeechEngine]
  ) async throws {
    try await database.write { db in
      for value in values {
        var record = try HTTPTextToSpeechRecord(value: value)
        try record.save(db)
      }
    }
  }

  public func localTextTOCRules() async throws -> [LocalTextTOCRule] {
    try await database.read { db in
      try LocalTextTOCRuleRecord
        .order(Column("serialNumber").asc, Column("id").asc)
        .fetchAll(db)
        .map { try $0.value }
    }
  }

  public func restoreAndroidLocalTextTOCRules(
    _ values: [LocalTextTOCRule]
  ) async throws {
    try await database.write { db in
      for value in values {
        var record = try LocalTextTOCRuleRecord(value: value)
        try record.save(db)
      }
    }
  }

  public func androidReaderConfigBundle() async throws
    -> AndroidReaderConfigBundle?
  {
    try await database.read { db in
      let records = try AndroidReaderConfigRecord.fetchAll(db)
      guard !records.isEmpty else { return nil }
      let payloads = Dictionary(uniqueKeysWithValues: records.map { ($0.key, $0.payload) })
      return try AndroidReaderConfigBundle(
        stylesData: payloads["styles"],
        sharedStyleData: payloads["shared"]
      )
    }
  }

  public func restoreAndroidReaderConfigBundle(
    _ bundle: AndroidReaderConfigBundle
  ) async throws {
    let styles = try bundle.encodedStyles()
    let shared = try bundle.encodedSharedStyle()
    try await database.write { db in
      var stylesRecord = AndroidReaderConfigRecord(key: "styles", payload: styles)
      try stylesRecord.save(db)
      if let shared {
        var sharedRecord = AndroidReaderConfigRecord(key: "shared", payload: shared)
        try sharedRecord.save(db)
      }
    }
  }

  public func dictionaryRules() async throws -> [DictionaryRule] {
    try await database.read { db in
      try DictionaryRuleRecord
        .order(Column("sortNumber").asc, Column("name").asc)
        .fetchAll(db)
        .map { try $0.value }
    }
  }

  public func restoreAndroidDictionaryRules(
    _ values: [DictionaryRule]
  ) async throws {
    try await database.write { db in
      for value in values {
        var record = try DictionaryRuleRecord(value: value)
        try record.save(db)
      }
    }
  }

  public func keyboardAssists() async throws -> [KeyboardAssist] {
    try await database.read { db in
      try KeyboardAssistRecord
        .order(Column("type").asc, Column("serialNumber").asc, Column("key").asc)
        .fetchAll(db)
        .map { try $0.value }
    }
  }

  public func restoreAndroidKeyboardAssists(
    _ values: [KeyboardAssist]
  ) async throws {
    try await database.write { db in
      for value in values {
        var record = try KeyboardAssistRecord(value: value)
        try record.save(db)
      }
    }
  }

  public func appThemeProfiles() async throws -> [AppThemeProfile] {
    try await database.read { db in
      try AppThemeProfileRecord
        .order(Column("name").asc)
        .fetchAll(db)
        .map { try $0.value }
    }
  }

  public func restoreAndroidThemeProfiles(
    _ values: [AppThemeProfile]
  ) async throws {
    try await database.write { db in
      for value in values {
        var record = try AppThemeProfileRecord(value: value)
        try record.save(db)
      }
    }
  }

  public func directLinkUploadRule() async throws -> DirectLinkUploadRule? {
    try await database.read { db in
      try DirectLinkUploadRuleRecord.fetchOne(db, key: 1)?.value
    }
  }

  public func restoreAndroidDirectLinkUploadRule(
    _ value: DirectLinkUploadRule
  ) async throws {
    try await database.write { db in
      var record = try DirectLinkUploadRuleRecord(value: value)
      try record.save(db)
    }
  }

  public func restoreAndroidReadRecords(
    _ records: [LibraryDomain.ReadRecord]
  ) async throws {
    try await database.write { db in
      for value in records {
        var record = ReadRecordRecord(value: value)
        try record.save(db)
      }
    }
  }

  public func reset() async throws {
    try await database.write { db in
      _ = try SearchHistoryRecord.deleteAll(db)
      _ = try RuleSubscriptionRecord.deleteAll(db)
      _ = try RSSStarRecord.deleteAll(db)
      _ = try RSSSourceRecord.deleteAll(db)
      _ = try ReadRecordRecord.deleteAll(db)
      _ = try AndroidLibraryBookmarkRecord.deleteAll(db)
      _ = try AndroidLibraryGroupRecord.deleteAll(db)
      _ = try ReadingBookmarkRecord.deleteAll(db)
      _ = try ChapterContentRecord.deleteAll(db)
      _ = try ChapterRecord.deleteAll(db)
      _ = try BookRecord.deleteAll(db)
      try db.execute(sql: "DELETE FROM shelfPreferences")
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
    migrator.registerMigration("addReadingProgress") { db in
      try db.alter(table: "books") { table in
        table.add(column: "progressChapterIndex", .integer)
        table.add(column: "progressCharacterOffset", .integer)
        table.add(column: "progressChapterTitle", .text)
        table.add(column: "progressUpdatedAt", .integer)
      }
    }
    migrator.registerMigration("addShelfManagement") { db in
      try db.alter(table: "books") { table in
        table.add(
          column: "latestChapterTime",
          .integer
        ).notNull().defaults(to: 0)
        table.add(
          column: "latestCheckCount",
          .integer
        ).notNull().defaults(to: 0)
        table.add(
          column: "canUpdate",
          .boolean
        ).notNull().defaults(to: true)
      }
      try db.create(table: "shelfPreferences") { table in
        table.column("groupID", .integer).primaryKey()
        table.column("sortMode", .integer).notNull()
      }
      try db.create(table: "chapterContentCache") { table in
        table.column("bookID", .text).notNull()
        table.column("chapterID", .text).notNull()
        table.column("content", .text).notNull()
        table.primaryKey(["bookID", "chapterID"])
        table.foreignKey(
          ["bookID"],
          references: "books",
          columns: ["bookID"],
          onDelete: .cascade
        )
      }
    }
    migrator.registerMigration("addReaderBookmarks") { db in
      try db.create(table: "readingBookmarks") { table in
        table.column("bookmarkID", .text).primaryKey()
        table.column("bookID", .text).notNull().indexed()
        table.column("chapterID", .text).notNull()
        table.column("chapterIndex", .integer).notNull()
        table.column("characterOffset", .integer).notNull()
        table.column("chapterTitle", .text).notNull()
        table.column("excerpt", .text).notNull()
        table.column("createdAtMilliseconds", .integer).notNull()
        table.foreignKey(
          ["bookID"],
          references: "books",
          columns: ["bookID"],
          onDelete: .cascade
        )
        table.uniqueKey(
          ["bookID", "chapterID", "characterOffset"]
        )
      }
    }
    migrator.registerMigration("addReaderReplacementRules") { db in
      try db.create(table: "readerReplacementRules") { table in
        table.column("ruleID", .text).primaryKey()
        table.column("name", .text).notNull()
        table.column("pattern", .text).notNull()
        table.column("replacement", .text).notNull()
        table.column("scope", .text)
        table.column("excludeScope", .text)
        table.column("appliesToTitle", .boolean).notNull()
        table.column("appliesToContent", .boolean).notNull()
        table.column("isEnabled", .boolean).notNull()
        table.column("isRegex", .boolean).notNull()
        table.column("orderValue", .integer).notNull().indexed()
      }
    }
    migrator.registerMigration("preserveSourceRequestExpressions") { db in
      try db.alter(table: "books") { table in
        table.add(
          column: "bookRequestExpression",
          .text
        ).notNull().defaults(to: "")
      }
      try db.execute(
        sql: """
          UPDATE books
          SET bookRequestExpression = bookURL
          WHERE bookRequestExpression = ''
          """
      )
      try db.alter(table: "chapters") { table in
        table.add(
          column: "requestExpression",
          .text
        ).notNull().defaults(to: "")
      }
      try db.execute(
        sql: """
          UPDATE chapters
          SET requestExpression = url
          WHERE requestExpression = ''
          """
      )
    }
    migrator.registerMigration("preserveSourceVariables") { db in
      try db.alter(table: "books") { table in
        table.add(
          column: "variablesJSON",
          .text
        ).notNull().defaults(to: "{}")
      }
      try db.alter(table: "chapters") { table in
        table.add(
          column: "variablesJSON",
          .text
        ).notNull().defaults(to: "{}")
      }
    }
    migrator.registerMigration("addLocalTextChapterSplitting") { db in
      try db.alter(table: "books") { table in
        table.add(
          column: "splitsLongChapters",
          .boolean
        ).notNull().defaults(to: true)
      }
    }
    migrator.registerMigration("preserveBookTOCURL") { db in
      try db.alter(table: "books") { table in
        table.add(column: "tocURL", .text)
      }
    }
    migrator.registerMigration("addBookMetadataOverrides") { db in
      try db.alter(table: "books") { table in
        table.add(column: "customCoverURL", .text)
        table.add(column: "customIntro", .text)
      }
    }
    migrator.registerMigration("addAndroidLibraryBackupInterop") { db in
      try db.alter(table: "books") { table in
        table.add(column: "lastCheckTime", .integer)
          .notNull().defaults(to: 0)
        table.add(column: "reversesTableOfContents", .boolean)
          .notNull().defaults(to: false)
        table.add(column: "androidType", .integer)
          .notNull().defaults(to: 0)
        table.add(column: "originOrder", .integer)
          .notNull().defaults(to: 0)
        table.add(column: "syncTime", .integer)
          .notNull().defaults(to: 0)
        table.add(column: "charset", .text)
        table.add(column: "customTag", .text)
        table.add(column: "wordCount", .text)
      }
      try db.create(table: "androidLibraryGroups") { table in
        table.column("groupID", .integer).primaryKey()
        table.column("name", .text).notNull()
        table.column("cover", .text)
        table.column("orderValue", .integer).notNull()
        table.column("enablesRefresh", .boolean).notNull()
        table.column("isShown", .boolean).notNull()
        table.column("bookSort", .integer).notNull()
      }
      try db.create(table: "androidLibraryBookmarks") { table in
        table.column("time", .integer).primaryKey()
        table.column("bookName", .text).notNull().indexed()
        table.column("bookAuthor", .text).notNull().indexed()
        table.column("chapterIndex", .integer).notNull()
        table.column("chapterPosition", .integer).notNull()
        table.column("chapterName", .text).notNull()
        table.column("bookText", .text).notNull()
        table.column("content", .text).notNull()
      }
    }
    migrator.registerMigration("preserveBookReplacementRulePreference") { db in
      try db.alter(table: "books") { table in
        table.add(column: "usesReplacementRules", .boolean)
          .notNull().defaults(to: true)
      }
    }
    migrator.registerMigration("preserveBookTTSEngine") { db in
      try db.alter(table: "books") { table in
        table.add(column: "ttsEngine", .text)
      }
    }
    migrator.registerMigration("preserveBookImageStyle") { db in
      try db.alter(table: "books") { table in
        table.add(column: "imageStyle", .text)
      }
    }
    migrator.registerMigration("addAndroidReadRecordInterop") { db in
      try db.create(table: "readRecords") { table in
        table.column("deviceID", .text).notNull()
        table.column("bookName", .text).notNull()
        table.column("readTime", .integer).notNull()
        table.column("lastRead", .integer).notNull().indexed()
        table.primaryKey(["deviceID", "bookName"])
      }
    }
    migrator.registerMigration("addSearchHistoryInterop") { db in
      try db.create(table: "searchHistory") { table in
        table.column("word", .text).notNull().primaryKey()
        table.column("usage", .integer).notNull()
        table.column("lastUseTime", .integer).notNull().indexed()
      }
    }
    migrator.registerMigration("addRuleSubscriptionInterop") { db in
      try db.create(table: "ruleSubscriptions") { table in
        table.column("id", .integer).notNull().primaryKey()
        table.column("name", .text).notNull()
        table.column("url", .text).notNull().indexed()
        table.column("type", .integer).notNull()
        table.column("customOrder", .integer).notNull().indexed()
        table.column("autoUpdate", .boolean).notNull()
        table.column("updatedAt", .integer).notNull()
      }
    }
    migrator.registerMigration("addRSSInterop") { db in
      try db.create(table: "rssSources") { table in
        table.column("sourceURL", .text).notNull().primaryKey()
        table.column("sourceName", .text).notNull()
        table.column("sourceGroup", .text)
        table.column("enabled", .boolean).notNull().indexed()
        table.column("customOrder", .integer).notNull().indexed()
        table.column("payload", .blob).notNull()
      }
      try db.create(table: "rssStars") { table in
        table.column("origin", .text).notNull()
        table.column("link", .text).notNull()
        table.column("starTime", .integer).notNull().indexed()
        table.column("payload", .blob).notNull()
        table.primaryKey(["origin", "link"])
      }
    }
    migrator.registerMigration("addHTTPTextToSpeechInterop") { db in
      try db.create(table: "httpTextToSpeechEngines") { table in
        table.column("id", .integer).notNull().primaryKey()
        table.column("name", .text).notNull().indexed()
        table.column("payload", .blob).notNull()
      }
    }
    migrator.registerMigration("addLocalTextTOCRuleInterop") { db in
      try db.create(table: "localTextTOCRules") { table in
        table.column("id", .integer).notNull().primaryKey()
        table.column("serialNumber", .integer).notNull().indexed()
        table.column("payload", .blob).notNull()
      }
    }
    migrator.registerMigration("addAndroidReaderConfigInterop") { db in
      try db.create(table: "androidReaderConfigs") { table in
        table.column("key", .text).notNull().primaryKey()
        table.column("payload", .blob).notNull()
      }
    }
    migrator.registerMigration("addAndroidDictionaryRuleInterop") { db in
      try db.create(table: "dictionaryRules") { table in
        table.column("name", .text).notNull().primaryKey()
        table.column("enabled", .boolean).notNull().indexed()
        table.column("sortNumber", .integer).notNull().indexed()
        table.column("payload", .blob).notNull()
      }
    }
    migrator.registerMigration("addAndroidKeyboardAssistInterop") { db in
      try db.create(table: "keyboardAssists") { table in
        table.column("type", .integer).notNull()
        table.column("key", .text).notNull()
        table.column("serialNumber", .integer).notNull().indexed()
        table.column("payload", .blob).notNull()
        table.primaryKey(["type", "key"])
      }
    }
    migrator.registerMigration("addAndroidThemeConfigInterop") { db in
      try db.create(table: "appThemeProfiles") { table in
        table.column("name", .text).notNull().primaryKey()
        table.column("night", .boolean).notNull().indexed()
        table.column("payload", .blob).notNull()
      }
    }
    migrator.registerMigration("addAndroidDirectLinkUploadRuleInterop") { db in
      try db.create(table: "directLinkUploadRule") { table in
        table.column("singleton", .integer).notNull().primaryKey()
        table.column("payload", .blob).notNull()
      }
    }
    migrator.registerMigration("addWebDAVServerProfileInterop") { db in
      try db.create(table: "webDAVServerProfiles") { table in
        table.column("id", .integer).notNull().primaryKey()
        table.column("name", .text).notNull()
        table.column("serverAddress", .text).notNull()
        table.column("sortNumber", .integer).notNull().indexed()
        table.column("credentialReference", .text).notNull().unique()
      }
      try db.create(table: "webDAVServerSelection") { table in
        table.column("singleton", .integer).notNull().primaryKey()
        table.column("selectedID", .integer).notNull()
      }
    }
    return migrator
  }

  private static func platformGroupMask(_ value: Int64) throws -> Int {
    guard let result = Int(exactly: value) else {
      throw AndroidLibraryImportError.integerOutOfRange(
        field: "group",
        value: value
      )
    }
    return result
  }
}

private struct WebDAVServerProfileRecord:
  Codable, FetchableRecord, MutablePersistableRecord
{
  static let databaseTableName = "webDAVServerProfiles"

  var id: Int64
  var name: String
  var serverAddress: String
  var sortNumber: Int
  var credentialReference: String

  init(value: WebDAVServerProfile) {
    id = value.id
    name = value.name
    serverAddress = value.serverAddress
    sortNumber = value.sortNumber
    credentialReference = value.credentialReference.rawValue
  }

  var value: WebDAVServerProfile {
    WebDAVServerProfile(
      id: id,
      name: name,
      serverAddress: serverAddress,
      sortNumber: sortNumber,
      credentialReference: .init(credentialReference)
    )
  }
}

private func localTextBaseTitle(_ title: String) -> String {
  guard
    title.hasSuffix(")"),
    let opening = title.lastIndex(of: "("),
    opening < title.index(before: title.endIndex),
    Int(title[title.index(after: opening)..<title.index(before: title.endIndex)])
      != nil
  else {
    return title
  }
  return String(title[..<opening])
}

private struct BookRecord:
  Codable, FetchableRecord, MutablePersistableRecord
{
  static let databaseTableName = "books"

  var bookID: String
  var bookURL: String
  var tocURL: String?
  var bookRequestExpression: String
  var name: String
  var author: String
  var kind: String
  var lastChapter: String
  var intro: String
  var coverURL: String?
  var customCoverURL: String?
  var customIntro: String?
  var originName: String
  var sourceID: String
  var variablesJSON: String
  var inBookshelf: Bool
  var groupID: Int
  var orderValue: Int64
  var chapterCount: Int
  var updateError: Bool
  var progressChapterIndex: Int?
  var progressCharacterOffset: Int?
  var progressChapterTitle: String?
  var progressUpdatedAt: Int64?
  var latestChapterTime: Int64
  var lastCheckTime: Int64
  var latestCheckCount: Int
  var canUpdate: Bool
  var reversesTableOfContents: Bool
  var splitsLongChapters: Bool
  var usesReplacementRules: Bool
  var ttsEngine: String?
  var imageStyle: String?
  var androidType: Int64
  var originOrder: Int64
  var syncTime: Int64
  var charset: String?
  var customTag: String?
  var wordCount: String?

  init(
    bookID: String,
    candidate: ShelfBookCandidate,
    membership: ShelfMembership,
    orderValue: Int64,
    chapterCount: Int
  ) {
    self.bookID = bookID
    self.bookURL = candidate.bookURL
    self.tocURL = candidate.tocURL
    self.bookRequestExpression = candidate.bookRequestExpression
    self.name = candidate.name
    self.author = candidate.author
    self.kind = candidate.kind
    self.lastChapter = candidate.lastChapter
    self.intro = candidate.intro
    self.coverURL = candidate.coverURL
    self.customCoverURL = candidate.customCoverURL
    self.customIntro = candidate.customIntro
    self.originName = candidate.originName
    self.sourceID = candidate.sourceID
    self.variablesJSON = SourceVariableJSON.encode(candidate.variables)
    self.inBookshelf = membership.isInBookshelf
    self.groupID = membership.groupID
    self.orderValue = orderValue
    self.chapterCount = chapterCount
    self.updateError = false
    self.progressChapterIndex = nil
    self.progressCharacterOffset = nil
    self.progressChapterTitle = nil
    self.progressUpdatedAt = nil
    self.latestChapterTime = 0
    self.lastCheckTime = 0
    self.latestCheckCount = 0
    self.canUpdate = true
    self.reversesTableOfContents = false
    self.splitsLongChapters = true
    self.usesReplacementRules = true
    self.ttsEngine = nil
    self.imageStyle = nil
    self.androidType = 0
    self.originOrder = 0
    self.syncTime = 0
    self.charset = nil
    self.customTag = nil
    self.wordCount = nil
  }

  mutating func apply(_ candidate: ShelfBookCandidate) {
    bookURL = candidate.bookURL
    if let candidateTOCURL = candidate.tocURL {
      tocURL = candidateTOCURL
    }
    bookRequestExpression = candidate.bookRequestExpression
    name = candidate.name
    author = candidate.author
    kind = candidate.kind
    lastChapter = candidate.lastChapter
    intro = candidate.intro
    coverURL = candidate.coverURL
    if let candidateCustomCoverURL = candidate.customCoverURL {
      customCoverURL = candidateCustomCoverURL
    }
    if let candidateCustomIntro = candidate.customIntro {
      customIntro = candidateCustomIntro
    }
    originName = candidate.originName
    sourceID = candidate.sourceID
    variablesJSON = SourceVariableJSON.encode(candidate.variables)
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
        tocURL: tocURL,
        bookRequestExpression: bookRequestExpression,
        coverURL: coverURL,
        customCoverURL: customCoverURL,
        customIntro: customIntro,
        originName: originName,
        sourceID: sourceID,
        variables: SourceVariableJSON.decode(variablesJSON)
      ),
      membership: inBookshelf
        ? .member(groupID: groupID)
        : .staged,
      order: orderValue,
      chapterCount: chapterCount,
      progress: readingProgress,
      latestChapterTime: latestChapterTime,
      lastCheckTime: lastCheckTime,
      latestCheckCount: latestCheckCount,
      canUpdate: canUpdate,
      reversesTableOfContents: reversesTableOfContents,
      splitsLongChapters: splitsLongChapters,
      usesReplacementRules: usesReplacementRules,
      ttsEngine: ttsEngine,
      imageStyle: imageStyle
    )
  }

  private var readingProgress: ReadingProgress? {
    guard
      let progressChapterIndex,
      let progressCharacterOffset,
      let progressUpdatedAt
    else {
      return nil
    }
    return ReadingProgress(
      position: ReadingPosition(
        chapterIndex: progressChapterIndex,
        characterOffset: progressCharacterOffset
      ),
      chapterTitle: progressChapterTitle,
      updatedAtMilliseconds: progressUpdatedAt
    )
  }

  var androidRestoreValue: AndroidLibraryRestoreBook {
    AndroidLibraryRestoreBook(
      candidate: item.candidate,
      groupMask: Int64(groupID),
      order: orderValue,
      chapterCount: chapterCount,
      progress: readingProgress ?? ReadingProgress(
        position: ReadingPosition(chapterIndex: 0, characterOffset: 0),
        chapterTitle: nil,
        updatedAtMilliseconds: 0
      ),
      latestChapterTime: latestChapterTime,
      lastCheckTime: lastCheckTime,
      latestCheckCount: latestCheckCount,
      canUpdate: canUpdate,
      reversesTableOfContents: reversesTableOfContents,
      splitsLongChapters: splitsLongChapters,
      usesReplacementRules: usesReplacementRules,
      ttsEngine: ttsEngine,
      imageStyle: imageStyle,
      androidType: androidType,
      originOrder: originOrder,
      syncTime: syncTime,
      charset: charset,
      customTag: customTag,
      wordCount: wordCount
    )
  }
}

private struct AndroidLibraryGroupRecord:
  Codable, FetchableRecord, MutablePersistableRecord
{
  static let databaseTableName = "androidLibraryGroups"

  var groupID: Int64
  var name: String
  var cover: String?
  var orderValue: Int
  var enablesRefresh: Bool
  var isShown: Bool
  var bookSort: Int

  init(value: AndroidLibraryRestoreGroup) {
    groupID = value.id
    name = value.name
    cover = value.cover
    orderValue = value.order
    enablesRefresh = value.enablesRefresh
    isShown = value.isShown
    bookSort = value.bookSort
  }

  var value: AndroidLibraryRestoreGroup {
    AndroidLibraryRestoreGroup(
      id: groupID,
      name: name,
      cover: cover,
      order: orderValue,
      enablesRefresh: enablesRefresh,
      isShown: isShown,
      bookSort: bookSort
    )
  }
}

private struct AndroidLibraryBookmarkRecord:
  Codable, FetchableRecord, MutablePersistableRecord
{
  static let databaseTableName = "androidLibraryBookmarks"

  var time: Int64
  var bookName: String
  var bookAuthor: String
  var chapterIndex: Int
  var chapterPosition: Int
  var chapterName: String
  var bookText: String
  var content: String

  init(value: LibraryDomain.Bookmark) {
    time = value.time
    bookName = value.bookName
    bookAuthor = value.bookAuthor
    chapterIndex = value.chapterIndex
    chapterPosition = value.chapterPosition
    chapterName = value.chapterName
    bookText = value.bookText
    content = value.content
  }

  var value: LibraryDomain.Bookmark {
    LibraryDomain.Bookmark(
      time: time,
      bookName: bookName,
      bookAuthor: bookAuthor,
      chapterIndex: chapterIndex,
      chapterPosition: chapterPosition,
      chapterName: chapterName,
      bookText: bookText,
      content: content
    )
  }
}

private struct ReadRecordRecord:
  Codable, FetchableRecord, MutablePersistableRecord
{
  static let databaseTableName = "readRecords"

  var deviceID: String
  var bookName: String
  var readTime: Int64
  var lastRead: Int64

  init(value: LibraryDomain.ReadRecord) {
    deviceID = value.deviceID
    bookName = value.bookName
    readTime = value.readTime
    lastRead = value.lastRead
  }

  var value: LibraryDomain.ReadRecord {
    LibraryDomain.ReadRecord(
      deviceID: deviceID,
      bookName: bookName,
      readTime: readTime,
      lastRead: lastRead
    )
  }
}

private struct SearchHistoryRecord:
  Codable, FetchableRecord, MutablePersistableRecord
{
  static let databaseTableName = "searchHistory"

  var word: String
  var usage: Int
  var lastUseTime: Int64

  init(value: SearchHistoryEntry) {
    word = value.word
    usage = value.usage
    lastUseTime = value.lastUseTime
  }

  var value: SearchHistoryEntry {
    SearchHistoryEntry(word: word, usage: usage, lastUseTime: lastUseTime)
  }
}

private struct RuleSubscriptionRecord:
  Codable, FetchableRecord, MutablePersistableRecord
{
  static let databaseTableName = "ruleSubscriptions"

  var id: Int64
  var name: String
  var url: String
  var type: Int
  var customOrder: Int
  var autoUpdate: Bool
  var updatedAt: Int64

  init(value: RuleSubscription) {
    id = value.id
    name = value.name
    url = value.url
    type = value.type
    customOrder = value.customOrder
    autoUpdate = value.autoUpdate
    updatedAt = value.updatedAt
  }

  var value: RuleSubscription {
    RuleSubscription(
      id: id,
      name: name,
      url: url,
      type: type,
      customOrder: customOrder,
      autoUpdate: autoUpdate,
      updatedAt: updatedAt
    )
  }
}

private struct RSSSourceRecord:
  Codable, FetchableRecord, MutablePersistableRecord
{
  static let databaseTableName = "rssSources"

  var sourceURL: String
  var sourceName: String
  var sourceGroup: String?
  var enabled: Bool
  var customOrder: Int
  var payload: Data

  init(value: RSSSource) throws {
    sourceURL = value.sourceURL
    sourceName = value.sourceName
    sourceGroup = value.sourceGroup
    enabled = value.enabled
    customOrder = value.customOrder
    payload = try JSONEncoder().encode(value)
  }

  var value: RSSSource { get throws { try JSONDecoder().decode(RSSSource.self, from: payload) } }
}

private struct RSSStarRecord:
  Codable, FetchableRecord, MutablePersistableRecord
{
  static let databaseTableName = "rssStars"

  var origin: String
  var link: String
  var starTime: Int64
  var payload: Data

  init(value: RSSStar) throws {
    origin = value.origin
    link = value.link
    starTime = value.starTime
    payload = try JSONEncoder().encode(value)
  }

  var value: RSSStar { get throws { try JSONDecoder().decode(RSSStar.self, from: payload) } }
}

private struct HTTPTextToSpeechRecord:
  Codable, FetchableRecord, MutablePersistableRecord
{
  static let databaseTableName = "httpTextToSpeechEngines"

  var id: Int64
  var name: String
  var payload: Data

  init(value: HTTPTextToSpeechEngine) throws {
    id = value.id
    name = value.name
    payload = try JSONEncoder().encode(value)
  }

  var value: HTTPTextToSpeechEngine {
    get throws {
      try JSONDecoder().decode(HTTPTextToSpeechEngine.self, from: payload)
    }
  }
}

private struct LocalTextTOCRuleRecord:
  Codable, FetchableRecord, MutablePersistableRecord
{
  static let databaseTableName = "localTextTOCRules"

  var id: Int64
  var serialNumber: Int
  var payload: Data

  init(value: LocalTextTOCRule) throws {
    id = value.id
    serialNumber = value.serialNumber
    payload = try JSONEncoder().encode(value)
  }

  var value: LocalTextTOCRule {
    get throws {
      try JSONDecoder().decode(LocalTextTOCRule.self, from: payload)
    }
  }
}

private struct AndroidReaderConfigRecord:
  Codable, FetchableRecord, MutablePersistableRecord
{
  static let databaseTableName = "androidReaderConfigs"
  var key: String
  var payload: Data
}

private struct DictionaryRuleRecord:
  Codable, FetchableRecord, MutablePersistableRecord
{
  static let databaseTableName = "dictionaryRules"
  var name: String
  var enabled: Bool
  var sortNumber: Int
  var payload: Data

  init(value: DictionaryRule) throws {
    name = value.name
    enabled = value.isEnabled
    sortNumber = value.sortNumber
    payload = try JSONEncoder().encode(value)
  }

  var value: DictionaryRule {
    get throws { try JSONDecoder().decode(DictionaryRule.self, from: payload) }
  }
}

private struct KeyboardAssistRecord:
  Codable, FetchableRecord, MutablePersistableRecord
{
  static let databaseTableName = "keyboardAssists"
  var type: Int
  var key: String
  var serialNumber: Int
  var payload: Data

  init(value: KeyboardAssist) throws {
    type = value.type
    key = value.key
    serialNumber = value.serialNumber
    payload = try JSONEncoder().encode(value)
  }

  var value: KeyboardAssist {
    get throws { try JSONDecoder().decode(KeyboardAssist.self, from: payload) }
  }
}

private struct AppThemeProfileRecord:
  Codable, FetchableRecord, MutablePersistableRecord
{
  static let databaseTableName = "appThemeProfiles"
  var name: String
  var night: Bool
  var payload: Data

  init(value: AppThemeProfile) throws {
    name = value.name
    night = value.isNightTheme
    payload = try JSONEncoder().encode(value)
  }

  var value: AppThemeProfile {
    get throws { try JSONDecoder().decode(AppThemeProfile.self, from: payload) }
  }
}

private struct DirectLinkUploadRuleRecord:
  Codable, FetchableRecord, MutablePersistableRecord
{
  static let databaseTableName = "directLinkUploadRule"
  var singleton = 1
  var payload: Data

  init(value: DirectLinkUploadRule) throws {
    payload = try JSONEncoder().encode(value)
  }

  var value: DirectLinkUploadRule {
    get throws {
      try JSONDecoder().decode(DirectLinkUploadRule.self, from: payload)
    }
  }
}

private struct ChapterContentRecord:
  Codable, FetchableRecord, MutablePersistableRecord
{
  static let databaseTableName = "chapterContentCache"

  var bookID: String
  var chapterID: String
  var content: String
}

private struct ReadingBookmarkRecord:
  Codable, FetchableRecord, MutablePersistableRecord
{
  static let databaseTableName = "readingBookmarks"

  var bookmarkID: String
  var bookID: String
  var chapterID: String
  var chapterIndex: Int
  var characterOffset: Int
  var chapterTitle: String
  var excerpt: String
  var createdAtMilliseconds: Int64

  init(bookmark: ReadingBookmark) {
    bookmarkID = bookmark.id
    bookID = bookmark.bookID.rawValue
    chapterID = bookmark.chapterID.rawValue
    chapterIndex = bookmark.chapterIndex
    characterOffset = bookmark.characterOffset
    chapterTitle = bookmark.chapterTitle
    excerpt = bookmark.excerpt
    createdAtMilliseconds = bookmark.createdAtMilliseconds
  }

  var bookmark: ReadingBookmark {
    ReadingBookmark(
      id: bookmarkID,
      bookID: BookID(rawValue: bookID),
      chapterID: ChapterID(rawValue: chapterID),
      chapterIndex: chapterIndex,
      characterOffset: characterOffset,
      chapterTitle: chapterTitle,
      excerpt: excerpt,
      createdAtMilliseconds: createdAtMilliseconds
    )
  }
}

private struct ReaderReplacementRuleRecord:
  Codable, FetchableRecord, MutablePersistableRecord
{
  static let databaseTableName = "readerReplacementRules"

  var ruleID: String
  var name: String
  var pattern: String
  var replacement: String
  var scope: String?
  var excludeScope: String?
  var appliesToTitle: Bool
  var appliesToContent: Bool
  var isEnabled: Bool
  var isRegex: Bool
  var orderValue: Int

  init(rule: ReaderReplacementRule) {
    ruleID = rule.id
    name = rule.name
    pattern = rule.pattern
    replacement = rule.replacement
    scope = rule.scope
    excludeScope = rule.excludeScope
    appliesToTitle = rule.appliesToTitle
    appliesToContent = rule.appliesToContent
    isEnabled = rule.isEnabled
    isRegex = rule.isRegex
    orderValue = rule.order
  }

  var rule: ReaderReplacementRule {
    ReaderReplacementRule(
      id: ruleID,
      name: name,
      pattern: pattern,
      replacement: replacement,
      scope: scope,
      excludeScope: excludeScope,
      appliesToTitle: appliesToTitle,
      appliesToContent: appliesToContent,
      isEnabled: isEnabled,
      isRegex: isRegex,
      order: orderValue
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
  var requestExpression: String
  var isPay: Bool
  var isVIP: Bool
  var isVolume: Bool
  var variablesJSON: String

  init(chapter: LibraryDomain.BookChapter) {
    chapterID = chapter.id.rawValue
    bookID = chapter.bookID.rawValue
    sourceID = chapter.sourceID
    chapterIndex = chapter.index
    title = chapter.title
    url = chapter.url
    requestExpression = chapter.requestExpression
    isPay = chapter.isPay
    isVIP = chapter.isVIP
    isVolume = chapter.isVolume
    variablesJSON = SourceVariableJSON.encode(chapter.variables)
  }

  var chapter: LibraryDomain.BookChapter {
    LibraryDomain.BookChapter(
      id: LibraryDomain.ChapterID(rawValue: chapterID),
      bookID: LibraryDomain.BookID(rawValue: bookID),
      sourceID: sourceID,
      index: chapterIndex,
      title: title,
      url: url,
      requestExpression: requestExpression,
      isPay: isPay,
      isVIP: isVIP,
      isVolume: isVolume,
      variables: SourceVariableJSON.decode(variablesJSON)
    )
  }
}

private enum SourceVariableJSON {
  static func encode(_ variables: [String: String]) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard
      let data = try? encoder.encode(variables),
      let value = String(data: data, encoding: .utf8)
    else {
      return "{}"
    }
    return value
  }

  static func decode(_ value: String) -> [String: String] {
    guard let data = value.data(using: .utf8) else { return [:] }
    return (try? JSONDecoder().decode(
      [String: String].self,
      from: data
    )) ?? [:]
  }
}
