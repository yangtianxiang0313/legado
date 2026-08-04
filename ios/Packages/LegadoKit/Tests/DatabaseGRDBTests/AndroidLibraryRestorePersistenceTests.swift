import AppUseCases
import BackupInteropUseCases
import DatabaseGRDB
import Foundation
import LibraryDomain
import Testing

@Suite("AndroidLibraryRestorePersistenceTests")
struct AndroidLibraryRestorePersistenceTests {
  @MainActor
  @Test func nativeReadingSessionsAccumulateWithoutCountingBackgroundTime()
    async throws
  {
    let databaseURL = temporaryDatabaseURL()
    defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
    let repository = try GRDBBookShelfRepository(path: databaseURL.path)
    let library = ShelfLibrary(
      repository: repository,
      readRecordDeviceID: "ios-device"
    )

    await library.beginReadingRecord(
      bookName: "互通测试书",
      atMilliseconds: 1_000
    )
    await library.settleReadingRecord(atMilliseconds: 4_500)
    await library.beginReadingRecord(
      bookName: "互通测试书",
      atMilliseconds: 20_000
    )
    await library.settleReadingRecord(atMilliseconds: 22_500)

    let records = try await repository.androidReadRecords()
    #expect(
      records == [
        ReadRecord(
          deviceID: "ios-device",
          bookName: "互通测试书",
          readTime: 5,
          lastRead: 22_500
        )
      ]
    )
  }

  @MainActor
  @Test func disabledReadingHistoryPreservesExistingRecordsAndDropsActiveSession()
    async throws
  {
    let databaseURL = temporaryDatabaseURL()
    defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
    let repository = try GRDBBookShelfRepository(path: databaseURL.path)
    let library = ShelfLibrary(
      repository: repository,
      readRecordDeviceID: "ios-device"
    )
    let existing = ReadRecord(
      deviceID: "android-device",
      bookName: "互通测试书",
      readTime: 9,
      lastRead: 900
    )
    try await repository.restoreAndroidReadRecords([existing])

    await library.beginReadingRecord(
      bookName: "互通测试书",
      enabled: false,
      atMilliseconds: 1_000
    )
    await library.settleReadingRecord(
      enabled: false,
      atMilliseconds: 5_000
    )
    await library.beginReadingRecord(
      bookName: "互通测试书",
      enabled: true,
      atMilliseconds: 10_000
    )
    await library.settleReadingRecord(
      enabled: false,
      atMilliseconds: 14_000
    )

    #expect(try await repository.androidReadRecords() == [existing])
  }

  @Test func atomicallyUpsertsCompleteAndroidLibraryPlan() async throws {
    let databaseURL = temporaryDatabaseURL()
    defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
    let repository = try GRDBBookShelfRepository(path: databaseURL.path)
    let existing = try await repository.add(
      candidate(
        name: "Old Name",
        bookURL: "https://android.invalid/book"
      ),
      groupID: 0
    )
    let plan = AndroidLibraryRestorePlan(
      books: [restoreBook()],
      groups: [
        AndroidLibraryRestoreGroup(
          id: 8,
          name: "Android Group",
          cover: "group-cover",
          order: 4,
          enablesRefresh: false,
          isShown: true,
          bookSort: 2
        )
      ],
      bookmarks: [bookmark(content: "context")]
    )

    let summary = try await repository.restoreAndroidLibrary(plan)
    let stored = try #require(
      await repository.book(forURL: "https://android.invalid/book")
    )
    let restored = try await repository.restoredAndroidLibraryPlan()
    let storedRestoreBook = try #require(restored.books.first)

    #expect(
      summary
        == AndroidLibraryRestoreSummary(
          bookCount: 1,
          groupCount: 1,
          bookmarkCount: 1
        ))
    #expect(stored.id == existing.id)
    #expect(stored.candidate.name == "Android Book")
    #expect(stored.membership.groupID == 9)
    #expect(stored.order == 6)
    #expect(stored.progress?.position.chapterIndex == 3)
    #expect(stored.progress?.position.characterOffset == 27)
    #expect(stored.chapterCount == 10)
    #expect(storedRestoreBook.lastCheckTime == 1_700_000_000_100)
    #expect(storedRestoreBook.reversesTableOfContents)
    #expect(!storedRestoreBook.splitsLongChapters)
    #expect(!stored.usesReplacementRules)
    #expect(!storedRestoreBook.usesReplacementRules)
    #expect(storedRestoreBook.androidType == 1)
    #expect(storedRestoreBook.originOrder == 2)
    #expect(storedRestoreBook.syncTime == 1_700_000_000_999)
    #expect(storedRestoreBook.charset == "GBK")
    #expect(storedRestoreBook.customTag == "favorite")
    #expect(storedRestoreBook.wordCount == "10000")
    #expect(restored.groups.map(\.id) == [8])
    #expect(restored.bookmarks.map(\.content) == ["context"])
  }

  @Test func repeatedRestoreUsesAndroidPrimaryKeysWithoutDeletingOtherBooks() async throws {
    let databaseURL = temporaryDatabaseURL()
    defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
    let repository = try GRDBBookShelfRepository(path: databaseURL.path)
    _ = try await repository.add(
      candidate(name: "iOS Only", bookURL: "https://ios.invalid/book"),
      groupID: 0
    )
    _ = try await repository.restoreAndroidLibrary(
      AndroidLibraryRestorePlan(
        books: [restoreBook()],
        groups: [group(name: "Before")],
        bookmarks: [bookmark(content: "before")]
      )
    )
    _ = try await repository.restoreAndroidLibrary(
      AndroidLibraryRestorePlan(
        books: [],
        groups: [group(name: "After")],
        bookmarks: [bookmark(content: "after")]
      )
    )

    let restored = try await repository.restoredAndroidLibraryPlan()

    #expect(restored.books.count == 2)
    #expect(restored.groups.count == 1)
    #expect(restored.groups.first?.name == "After")
    #expect(restored.bookmarks.count == 1)
    #expect(restored.bookmarks.first?.content == "after")
  }

  @Test func restoredAndroidBookmarkJoinsLoadedChapterAndCanBeRemoved()
    async throws
  {
    let databaseURL = temporaryDatabaseURL()
    defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
    let repository = try GRDBBookShelfRepository(path: databaseURL.path)
    let book = try await repository.add(
      candidate(
        name: "Android Book",
        bookURL: "https://android.invalid/book"
      ),
      groupID: 0
    )
    let chapter = BookChapter(
      id: ChapterID(rawValue: "android-chapter-four"),
      bookID: book.id,
      sourceID: book.candidate.sourceID,
      index: 3,
      title: "Loaded Chapter Four",
      url: "https://android.invalid/book/chapter-4"
    )
    _ = try await repository.applyTOCUpdate(
      bookID: book.id,
      update: .replaced(previousCount: 0, chapters: [chapter])
    )
    _ = try await repository.restoreAndroidLibrary(
      AndroidLibraryRestorePlan(
        books: [],
        groups: [],
        bookmarks: [bookmark(content: "Android note")]
      )
    )

    let projected = try #require(
      try await repository.bookmarks(bookID: book.id).first
    )
    let stableID = ReadingBookmark.stableID(
      bookID: book.id,
      chapterID: chapter.id,
      characterOffset: 27
    )
    #expect(projected.id == stableID)
    #expect(projected.chapterID == chapter.id)
    #expect(projected.chapterIndex == 3)
    #expect(projected.characterOffset == 27)
    #expect(projected.chapterTitle == "Chapter Four")
    #expect(projected.excerpt == "Android note")
    #expect(projected.createdAtMilliseconds == 1_700_000_000_123)

    try await repository.saveBookmark(
      ReadingBookmark(
        id: stableID,
        bookID: book.id,
        chapterID: chapter.id,
        chapterIndex: 3,
        characterOffset: 27,
        chapterTitle: "Native Chapter Four",
        excerpt: "iOS edit",
        createdAtMilliseconds: 1_700_000_000_456
      )
    )
    let merged = try await repository.bookmarks(bookID: book.id)
    #expect(merged.count == 1)
    #expect(merged.first?.excerpt == "iOS edit")

    try await repository.deleteBookmark(id: stableID)
    #expect(try await repository.bookmarks(bookID: book.id).isEmpty)
    #expect(try await repository.restoredAndroidLibraryPlan().bookmarks.isEmpty)
  }

  @MainActor
  @Test func projectsRestoredGroupNamesAndMultiGroupMembership() async throws {
    let databaseURL = temporaryDatabaseURL()
    defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
    let repository = try GRDBBookShelfRepository(path: databaseURL.path)
    _ = try await repository.restoreAndroidLibrary(
      AndroidLibraryRestorePlan(
        books: [restoreBook()],
        groups: [
          AndroidLibraryRestoreGroup(
            id: 1,
            name: "收藏",
            cover: nil,
            order: 1,
            enablesRefresh: true,
            isShown: true,
            bookSort: 0
          ),
          AndroidLibraryRestoreGroup(
            id: 8,
            name: "工作",
            cover: nil,
            order: 2,
            enablesRefresh: true,
            isShown: true,
            bookSort: 0
          )
        ],
        bookmarks: []
      )
    )
    let library = ShelfLibrary(repository: repository)

    await library.reload()
    #expect(library.availableGroups.map(\.name) == ["收藏", "工作"])

    await library.selectGroup(1)
    #expect(library.books.map(\.candidate.name) == ["Android Book"])
    await library.selectGroup(8)
    #expect(library.books.map(\.candidate.name) == ["Android Book"])
    await library.selectGroup(0)
    #expect(library.books.isEmpty)
  }

  @Test func includesNativeIOSBookmarksInAndroidBackupSnapshot() async throws {
    let databaseURL = temporaryDatabaseURL()
    defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
    let repository = try GRDBBookShelfRepository(path: databaseURL.path)
    let book = try await repository.add(
      candidate(name: "iOS Native", bookURL: "https://ios.invalid/native"),
      groupID: 0
    )
    try await repository.saveBookmark(
      ReadingBookmark(
        id: "ios-bookmark",
        bookID: book.id,
        chapterID: ChapterID(rawValue: "chapter-3"),
        chapterIndex: 3,
        characterOffset: 27,
        chapterTitle: "Chapter Four",
        excerpt: "native excerpt",
        createdAtMilliseconds: 1_700_000_000_456
      )
    )

    let plan = try await repository.androidLibraryBackupPlan()
    let bookmark = try #require(plan.bookmarks.first)

    #expect(bookmark.bookName == "iOS Native")
    #expect(bookmark.bookAuthor == "Android Author")
    #expect(bookmark.chapterIndex == 3)
    #expect(bookmark.chapterPosition == 27)
    #expect(bookmark.content == "native excerpt")
  }

  @Test func persistsReadRecordsByAndroidCompositePrimaryKey() async throws {
    let databaseURL = temporaryDatabaseURL()
    defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
    let repository = try GRDBBookShelfRepository(path: databaseURL.path)

    try await repository.restoreAndroidReadRecords([
      ReadRecord(
        deviceID: "android-a",
        bookName: "Book",
        readTime: 100,
        lastRead: 1_000
      ),
      ReadRecord(
        deviceID: "android-b",
        bookName: "Book",
        readTime: 200,
        lastRead: 2_000
      )
    ])
    try await repository.restoreAndroidReadRecords([
      ReadRecord(
        deviceID: "android-a",
        bookName: "Book",
        readTime: 300,
        lastRead: 3_000
      )
    ])

    let records = try await repository.androidReadRecords()

    #expect(records.count == 2)
    #expect(records.map(\.deviceID) == ["android-b", "android-a"])
    #expect(records.map(\.readTime) == [200, 300])
  }

  private func restoreBook() -> AndroidLibraryRestoreBook {
    AndroidLibraryRestoreBook(
      candidate: candidate(
        name: "Android Book",
        bookURL: "https://android.invalid/book"
      ),
      groupMask: 9,
      order: 6,
      chapterCount: 10,
      progress: ReadingProgress(
        position: ReadingPosition(chapterIndex: 3, characterOffset: 27),
        chapterTitle: "Chapter Four",
        updatedAtMilliseconds: 1_700_000_000_123
      ),
      latestChapterTime: 1_700_000_000_000,
      lastCheckTime: 1_700_000_000_100,
      latestCheckCount: 2,
      canUpdate: false,
      reversesTableOfContents: true,
      splitsLongChapters: false,
      usesReplacementRules: false,
      androidType: 1,
      originOrder: 2,
      syncTime: 1_700_000_000_999,
      charset: "GBK",
      customTag: "favorite",
      wordCount: "10000"
    )
  }

  private func candidate(
    name: String,
    bookURL: String
  ) -> ShelfBookCandidate {
    ShelfBookCandidate(
      name: name,
      author: "Android Author",
      kind: "fiction",
      lastChapter: "Chapter Ten",
      intro: "intro",
      bookURL: bookURL,
      tocURL: "https://android.invalid/toc",
      coverURL: "https://android.invalid/cover",
      customCoverURL: "custom-cover",
      customIntro: "custom-intro",
      originName: "Android Source",
      sourceID: "https://android.invalid/source",
      variables: ["token": "kept"]
    )
  }

  private func group(name: String) -> AndroidLibraryRestoreGroup {
    AndroidLibraryRestoreGroup(
      id: 8,
      name: name,
      cover: nil,
      order: 4,
      enablesRefresh: true,
      isShown: true,
      bookSort: 2
    )
  }

  private func bookmark(content: String) -> LibraryDomain.Bookmark {
    LibraryDomain.Bookmark(
      time: 1_700_000_000_123,
      bookName: "Android Book",
      bookAuthor: "Android Author",
      chapterIndex: 3,
      chapterPosition: 27,
      chapterName: "Chapter Four",
      bookText: "selected",
      content: content
    )
  }

  private func temporaryDatabaseURL() -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    return directory.appendingPathComponent("library.sqlite")
  }
}
