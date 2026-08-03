import AppUseCases
import BackupInteropUseCases
import DatabaseGRDB
import Foundation
import LibraryDomain
import Testing

@Suite("AndroidLibraryRestorePersistenceTests")
struct AndroidLibraryRestorePersistenceTests {
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
