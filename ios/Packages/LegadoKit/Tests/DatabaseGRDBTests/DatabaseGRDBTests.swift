import AppUseCases
import DatabaseGRDB
import LibraryDomain
import ReaderCore
import XCTest

@MainActor
final class DatabaseGRDBTests: XCTestCase {
  func testExactDependencyCanOpenAndUseSQLite() throws {
    XCTAssertTrue(
      try DatabaseGRDBRuntime.verifyInMemoryDatabase()
    )
  }

  func testStagedBookIsNotShelfMembershipAndAddSurvivesReopen() async throws {
    let verified = try await DatabaseGRDBRuntime
      .verifyShelfPersistenceAcrossReopen()
    XCTAssertTrue(verified)
  }

  func testTOCReplacementPersistsAndFailurePreservesOldSnapshot() async throws {
    let verified =
      try await DatabaseGRDBRuntime.verifyTOCPersistenceAcrossReopen()
    XCTAssertTrue(verified)
  }

  func testReadingProgressSurvivesRepositoryReopen() async throws {
    let verified =
      try await DatabaseGRDBRuntime.verifyProgressPersistenceAcrossReopen()
    XCTAssertTrue(verified)
  }

  func testReaderReplacementRulesSurviveReopenAndRetainOrder()
    async throws
  {
    let path = temporaryDatabasePath()
    let repository = try GRDBBookShelfRepository(path: path)
    let later = ReaderReplacementRule(
      id: "later",
      name: "后执行",
      pattern: "乙",
      replacement: "",
      order: 20
    )
    let earlier = ReaderReplacementRule(
      id: "earlier",
      name: "先执行",
      pattern: "甲",
      replacement: "乙",
      scope: "测试书",
      excludeScope: "排除源",
      appliesToTitle: true,
      appliesToContent: true,
      isEnabled: false,
      isRegex: false,
      order: 10
    )
    try await repository.saveReplacementRule(later)
    try await repository.saveReplacementRule(earlier)

    let reopened = try GRDBBookShelfRepository(path: path)
    let restored = try await reopened.replacementRules()
    XCTAssertEqual(restored, [earlier, later])

    try await reopened.deleteReplacementRule(id: earlier.id)
    let afterDelete = try await reopened.replacementRules()
    XCTAssertEqual(afterDelete, [later])
  }

  func testSourceSwitchAtomicallyPreservesStableIdentityAndProgress()
    async throws
  {
    let verified =
      try await DatabaseGRDBRuntime.verifyAtomicSourceSwitchAcrossReopen()
    XCTAssertTrue(verified)
  }

  func testShelfStatusSortAndGroupOverrideSurviveReopen() async throws {
    let path = temporaryDatabasePath()
    let repository = try GRDBBookShelfRepository(path: path)
    let alpha = try await repository.add(
      candidate(name: "阿尔法", suffix: "alpha"),
      groupID: 0
    )
    let beta = try await repository.add(
      candidate(name: "贝塔", suffix: "beta"),
      groupID: 0
    )
    let chapters = (0..<3).map { index in
      BookChapter(
        id: ChapterID(
          sourceID: alpha.candidate.sourceID,
          chapterURL: "\(alpha.candidate.bookURL)/\(index)"
        ),
        bookID: alpha.id,
        sourceID: alpha.candidate.sourceID,
        index: index,
        title: "第\(index + 1)章",
        url: "\(alpha.candidate.bookURL)/\(index)"
      )
    }
    _ = try await repository.applyTOCUpdate(
      bookID: alpha.id,
      update: .replaced(previousCount: 0, chapters: chapters)
    )
    let storedAfterTOC = try await repository.book(id: alpha.id)
    let updated = try XCTUnwrap(storedAfterTOC)
    XCTAssertEqual(updated.latestCheckCount, 3)
    XCTAssertGreaterThan(updated.latestChapterTime, 0)
    XCTAssertEqual(updated.unreadChapterCount, 2)

    try await repository.saveReadingProgress(
      bookID: alpha.id,
      progress: ReadingProgress(
        position: ReadingPosition(
          chapterIndex: 1,
          characterOffset: 0
        ),
        chapterTitle: "第二章",
        updatedAtMilliseconds: 9_000
      )
    )
    try await repository.setShelfSortMode(.name, groupID: nil)
    try await repository.setShelfSortMode(.manual, groupID: 0)

    let reopened = try GRDBBookShelfRepository(path: path)
    let storedAfterRead = try await reopened.book(id: alpha.id)
    let read = try XCTUnwrap(storedAfterRead)
    XCTAssertEqual(read.latestCheckCount, 0)
    XCTAssertEqual(read.unreadChapterCount, 1)
    let globalSort = try await reopened.shelfSortMode(groupID: nil)
    let groupSort = try await reopened.shelfSortMode(groupID: 0)
    let fallbackSort = try await reopened.shelfSortMode(groupID: 9)
    XCTAssertEqual(globalSort, .name)
    XCTAssertEqual(groupSort, .manual)
    XCTAssertEqual(fallbackSort, .name)

    let library = ShelfLibrary(repository: reopened)
    await library.reload()
    await library.setSortMode(.name, forCurrentGroup: false)
    XCTAssertEqual(library.books.map(\.id), [alpha.id, beta.id])
    await library.selectGroup(0)
    XCTAssertEqual(library.books.map(\.id), [beta.id, alpha.id])
    await library.moveBooks(
      fromOffsets: IndexSet(integer: 0),
      toOffset: 2
    )
    XCTAssertEqual(library.books.map(\.id), [alpha.id, beta.id])
    let afterMove = try GRDBBookShelfRepository(path: path)
    let restoredLibrary = ShelfLibrary(repository: afterMove)
    await restoredLibrary.reload()
    await restoredLibrary.selectGroup(0)
    XCTAssertEqual(
      restoredLibrary.books.map(\.id),
      [alpha.id, beta.id]
    )
  }

  func testShelfBatchMutationsKeepCommittedPrefixAndReportFailure()
    async throws
  {
    let repository = try GRDBBookShelfRepository(
      path: temporaryDatabasePath()
    )
    let first = try await repository.add(
      candidate(name: "第一本", suffix: "first"),
      groupID: 0
    )
    let second = try await repository.add(
      candidate(name: "第二本", suffix: "second"),
      groupID: 0
    )
    let missing = BookID(rawValue: "missing")
    let library = ShelfLibrary(repository: repository)
    await library.reload()

    let report = await library.performBatch(
      .setCanUpdate(false),
      bookIDs: [first.id, missing, second.id]
    )

    XCTAssertEqual(report.committedBookIDs, [first.id, second.id])
    XCTAssertEqual(report.failedBookIDs, [missing])
    XCTAssertTrue(report.isPartialCommit)
    let storedFirst = try await repository.book(id: first.id)
    let storedSecond = try await repository.book(id: second.id)
    XCTAssertFalse(try XCTUnwrap(storedFirst).canUpdate)
    XCTAssertFalse(try XCTUnwrap(storedSecond).canUpdate)

    _ = await library.performBatch(
      .moveToGroup(7),
      bookIDs: [first.id, second.id]
    )
    let moved = try await repository.book(id: first.id)
    XCTAssertEqual(moved?.membership.groupID, 7)
    _ = await library.performBatch(.clearCache, bookIDs: [first.id])
    _ = await library.performBatch(.delete, bookIDs: [second.id])
    let deleted = try await repository.book(id: second.id)
    XCTAssertNil(deleted)
  }

  func testBatchSourceSwitchCommitsSuccessAndContinuesAfterFailure()
    async throws
  {
    let repository = try GRDBBookShelfRepository(
      path: temporaryDatabasePath()
    )
    let first = try await repository.add(
      candidate(name: "第一本", suffix: "source-first"),
      groupID: 0
    )
    let second = try await repository.add(
      candidate(name: "第二本", suffix: "source-second"),
      groupID: 0
    )
    let library = ShelfLibrary(repository: repository)
    await library.reload()

    let report = await library.switchSources(
      bookIDs: [first.id, second.id],
      targetSourceID: "source://target"
    ) { current in
      guard current.id == first.id else {
        throw TestFailure.expected
      }
      let target = ShelfBookCandidate(
        name: current.candidate.name,
        author: current.candidate.author,
        kind: current.candidate.kind,
        lastChapter: "新第一章",
        intro: current.candidate.intro,
        bookURL: "\(current.candidate.bookURL)-target",
        coverURL: nil,
        originName: "目标源",
        sourceID: "source://target"
      )
      return (
        candidate: target,
        chapters: [
          BookChapter(
            id: ChapterID(
              sourceID: target.sourceID,
              chapterURL: "\(target.bookURL)/1"
            ),
            bookID: current.id,
            sourceID: target.sourceID,
            index: 0,
            title: "新第一章",
            url: "\(target.bookURL)/1"
          )
        ]
      )
    }

    XCTAssertEqual(report.committedBookIDs, [first.id])
    XCTAssertEqual(report.failedBookIDs, [second.id])
    XCTAssertTrue(report.isPartialCommit)
    let switched = try await repository.book(id: first.id)
    let preserved = try await repository.book(id: second.id)
    XCTAssertEqual(switched?.candidate.sourceID, "source://target")
    XCTAssertEqual(preserved?.candidate.sourceID, "source://test")
  }

  func testLocalTextImportPersistsContentAndKeepsIdentityOnReimport()
    async throws
  {
    let path = temporaryDatabasePath()
    let repository = try GRDBBookShelfRepository(path: path)
    let library = ShelfLibrary(repository: repository)
    let reference = "file:///managed/imported/local.txt"

    let first = await library.importLocalText(
      fileName: "《本地书》作者：林舟.txt",
      managedReference: reference,
      data: Data(
        """
        第一章 启程
        第一版正文
        第二章 回声
        回声落下
        """.utf8
      )
    )
    let imported = try XCTUnwrap(first)
    XCTAssertEqual(imported.candidate.name, "本地书")
    XCTAssertEqual(imported.candidate.author, "林舟")
    XCTAssertEqual(imported.chapterCount, 2)

    let chapters = try await repository.chapters(bookID: imported.id)
    XCTAssertEqual(chapters.map(\.title), ["第一章 启程", "第二章 回声"])
    let firstContent = try await repository.chapterContent(
      bookID: imported.id,
      chapterID: chapters[0].id
    )
    XCTAssertEqual(firstContent, "第一版正文")

    let reopened = try GRDBBookShelfRepository(path: path)
    let reopenedLibrary = ShelfLibrary(repository: reopened)
    let updated = await reopenedLibrary.importLocalText(
      fileName: "《本地书》作者：林舟.txt",
      managedReference: reference,
      data: Data(
        """
        第一章 启程
        更新后的正文
        """.utf8
      )
    )
    let reimported = try XCTUnwrap(updated)
    XCTAssertEqual(reimported.id, imported.id)
    XCTAssertEqual(reimported.chapterCount, 1)
    let updatedChapters = try await reopened.chapters(
      bookID: imported.id
    )
    let updatedContent = try await reopened.chapterContent(
      bookID: imported.id,
      chapterID: updatedChapters[0].id
    )
    XCTAssertEqual(updatedContent, "更新后的正文")
  }

  func testOfflineCacheRetriesPersistsSkipsAndReadsWithoutSource()
    async throws
  {
    let path = temporaryDatabasePath()
    let repository = try GRDBBookShelfRepository(path: path)
    let item = try await repository.add(
      candidate(name: "离线书", suffix: "offline"),
      groupID: 0
    )
    let chapters = (0..<2).map { index in
      BookChapter(
        id: ChapterID(
          sourceID: item.candidate.sourceID,
          chapterURL: "\(item.candidate.bookURL)/\(index)"
        ),
        bookID: item.id,
        sourceID: item.candidate.sourceID,
        index: index,
        title: "第\(index + 1)章",
        url: "\(item.candidate.bookURL)/\(index)"
      )
    }
    _ = try await repository.applyTOCUpdate(
      bookID: item.id,
      update: .replaced(previousCount: 0, chapters: chapters)
    )
    let library = ShelfLibrary(repository: repository)
    await library.reload()
    let source = RetryingReaderLoader(failuresBeforeSuccess: 2)

    let first = await library.cacheOffline(
      bookIDs: [item.id],
      loader: source
    )

    XCTAssertEqual(first.requestedCount, 2)
    XCTAssertEqual(first.cachedCount, 2)
    XCTAssertEqual(first.skippedCount, 0)
    XCTAssertEqual(first.failedCount, 0)
    let attemptCount = await source.attemptCount
    XCTAssertEqual(attemptCount, 6)

    let second = await library.cacheOffline(
      bookIDs: [item.id],
      loader: UnavailableReaderLoader()
    )
    XCTAssertEqual(second.cachedCount, 0)
    XCTAssertEqual(second.skippedCount, 2)

    let reopened = try GRDBBookShelfRepository(path: path)
    let reopenedLibrary = ShelfLibrary(repository: reopened)
    let reopenedBook = try await reopened.book(id: item.id)
    let storedBook = try XCTUnwrap(reopenedBook)
    let storedChapters = try await reopened.chapters(bookID: item.id)
    let offlineLoader = reopenedLibrary.readerContentLoader(
      fallback: UnavailableReaderLoader()
    )
    let document = try await offlineLoader.load(
      book: storedBook,
      chapter: storedChapters[0],
      characterOffset: 0
    )
    XCTAssertEqual(document.content, "离线正文 0")

    try await reopened.applyShelfMutation(
      .clearCache,
      bookID: item.id
    )
    do {
      _ = try await offlineLoader.load(
        book: storedBook,
        chapter: storedChapters[0],
        characterOffset: 0
      )
      XCTFail("Cleared cache must fall back to unavailable source")
    } catch {
      XCTAssertTrue(error is TestFailure)
    }
  }

  func testOfflineCacheSkipsLocalBookWithoutCallingRemoteLoader()
    async throws
  {
    let repository = try GRDBBookShelfRepository(
      path: temporaryDatabasePath()
    )
    let library = ShelfLibrary(repository: repository)
    let item = await library.importLocalText(
      fileName: "本地.txt",
      managedReference: "file:///managed/local.txt",
      data: Data("第一章 开始\n本地正文".utf8)
    )
    let local = try XCTUnwrap(item)
    let report = await library.cacheOffline(
      bookIDs: [local.id],
      loader: UnavailableReaderLoader()
    )

    XCTAssertEqual(report.requestedCount, 1)
    XCTAssertEqual(report.skippedCount, 1)
    XCTAssertEqual(report.failedCount, 0)
  }

  func testOfflineCacheHonorsSelectedChapterRange() async throws {
    let repository = try GRDBBookShelfRepository(
      path: temporaryDatabasePath()
    )
    let item = try await repository.add(
      candidate(name: "范围缓存", suffix: "offline-range"),
      groupID: 0
    )
    let chapters = (0..<4).map { index in
      BookChapter(
        id: ChapterID(
          sourceID: item.candidate.sourceID,
          chapterURL: "\(item.candidate.bookURL)/\(index)"
        ),
        bookID: item.id,
        sourceID: item.candidate.sourceID,
        index: index,
        title: "第\(index + 1)章",
        url: "\(item.candidate.bookURL)/\(index)"
      )
    }
    _ = try await repository.applyTOCUpdate(
      bookID: item.id,
      update: .replaced(previousCount: 0, chapters: chapters)
    )
    let library = ShelfLibrary(repository: repository)
    let loader = RetryingReaderLoader(failuresBeforeSuccess: 0)

    let report = await library.cacheOffline(
      bookID: item.id,
      chapterIndexes: 1...2,
      loader: loader
    )

    XCTAssertEqual(report.requestedCount, 2)
    XCTAssertEqual(report.cachedCount, 2)
    XCTAssertEqual(report.skippedCount, 0)
    XCTAssertEqual(report.failedCount, 0)
    var cachedContents: [String?] = []
    for chapter in chapters {
      cachedContents.append(
        try await repository.chapterContent(
          bookID: item.id,
          chapterID: chapter.id
        )
      )
    }
    XCTAssertNil(cachedContents[0])
    XCTAssertEqual(cachedContents[1], "离线正文 1")
    XCTAssertEqual(cachedContents[2], "离线正文 2")
    XCTAssertNil(cachedContents[3])
  }

  func testBookmarksAndFullTextSearchSurviveRepositoryReopen()
    async throws
  {
    let path = temporaryDatabasePath()
    let repository = try GRDBBookShelfRepository(path: path)
    let item = try await repository.add(
      candidate(name: "星河纪事", suffix: "reader-tools"),
      groupID: 0
    )
    let chapters = (0..<2).map { index in
      BookChapter(
        id: ChapterID(
          sourceID: item.candidate.sourceID,
          chapterURL: "\(item.candidate.bookURL)/\(index)"
        ),
        bookID: item.id,
        sourceID: item.candidate.sourceID,
        index: index,
        title: index == 0 ? "第一章 启航" : "第二章 回声",
        url: "\(item.candidate.bookURL)/\(index)"
      )
    }
    _ = try await repository.applyTOCUpdate(
      bookID: item.id,
      update: .replaced(previousCount: 0, chapters: chapters)
    )
    try await repository.saveChapterContent(
      "星港的晨光照亮甲板，晨光再次越过舷窗。",
      bookID: item.id,
      chapterID: chapters[0].id
    )
    try await repository.saveChapterContent(
      "山谷只有回声。",
      bookID: item.id,
      chapterID: chapters[1].id
    )
    let bookmark = ReadingBookmark(
      id: ReadingBookmark.stableID(
        bookID: item.id,
        chapterID: chapters[0].id,
        characterOffset: 4
      ),
      bookID: item.id,
      chapterID: chapters[0].id,
      chapterIndex: 0,
      characterOffset: 4,
      chapterTitle: chapters[0].title,
      excerpt: "星港的晨光",
      createdAtMilliseconds: 123
    )
    try await repository.saveBookmark(bookmark)
    try await repository.saveBookmark(bookmark)

    let reopened = try GRDBBookShelfRepository(path: path)
    let storedBookmarks = try await reopened.bookmarks(bookID: item.id)
    XCTAssertEqual(storedBookmarks, [bookmark])
    let library = ShelfLibrary(repository: reopened)
    let results = await library.searchBookContent(
      bookID: item.id,
      query: "晨光",
      loader: library.readerContentLoader(
        fallback: UnavailableReaderLoader()
      )
    )
    XCTAssertEqual(results.count, 2)
    XCTAssertEqual(results.map(\.chapterID), [chapters[0].id, chapters[0].id])
    XCTAssertEqual(results.map(\.characterOffset), [3, 10])

    try await reopened.deleteBookmark(id: bookmark.id)
    let deletedBookmarks = try await reopened.bookmarks(bookID: item.id)
    XCTAssertEqual(deletedBookmarks, [])
  }

  func testReaderContentRefreshScopesDeleteOnlyRequestedCache()
    async throws
  {
    let repository = try GRDBBookShelfRepository(
      path: temporaryDatabasePath()
    )
    let item = try await repository.add(
      candidate(name: "刷新测试", suffix: "refresh"),
      groupID: 0
    )
    let chapters = (0..<3).map { index in
      BookChapter(
        id: ChapterID(
          sourceID: item.candidate.sourceID,
          chapterURL: "\(item.candidate.bookURL)/\(index)"
        ),
        bookID: item.id,
        sourceID: item.candidate.sourceID,
        index: index,
        title: "第\(index + 1)章",
        url: "\(item.candidate.bookURL)/\(index)"
      )
    }
    _ = try await repository.applyTOCUpdate(
      bookID: item.id,
      update: .replaced(previousCount: 0, chapters: chapters)
    )
    for chapter in chapters {
      try await repository.saveChapterContent(
        "cache-\(chapter.index)",
        bookID: item.id,
        chapterID: chapter.id
      )
    }
    let library = ShelfLibrary(repository: repository)

    let invalidatedAfter = await library.invalidateReaderContent(
      bookID: item.id,
      currentChapterID: chapters[1].id,
      scope: .currentAndAfter
    )
    XCTAssertTrue(invalidatedAfter)
    let first = try await repository.chapterContent(
      bookID: item.id,
      chapterID: chapters[0].id
    )
    let second = try await repository.chapterContent(
      bookID: item.id,
      chapterID: chapters[1].id
    )
    let third = try await repository.chapterContent(
      bookID: item.id,
      chapterID: chapters[2].id
    )
    XCTAssertEqual(first, "cache-0")
    XCTAssertNil(second)
    XCTAssertNil(third)

    for chapter in chapters {
      try await repository.saveChapterContent(
        "cache-\(chapter.index)",
        bookID: item.id,
        chapterID: chapter.id
      )
    }
    let invalidatedAll = await library.invalidateReaderContent(
      bookID: item.id,
      currentChapterID: chapters[1].id,
      scope: .all
    )
    XCTAssertTrue(invalidatedAll)
    for chapter in chapters {
      let content = try await repository.chapterContent(
        bookID: item.id,
        chapterID: chapter.id
      )
      XCTAssertNil(content)
    }
  }

  func testChapterSourceContentReplacesOnlyCurrentCache()
    async throws
  {
    let path = temporaryDatabasePath()
    let repository = try GRDBBookShelfRepository(path: path)
    let item = try await repository.add(
      candidate(name: "章节换源", suffix: "chapter-source"),
      groupID: 0
    )
    let chapter = BookChapter(
      id: ChapterID(
        sourceID: item.candidate.sourceID,
        chapterURL: "\(item.candidate.bookURL)/current"
      ),
      bookID: item.id,
      sourceID: item.candidate.sourceID,
      index: 0,
      title: "当前章",
      url: "\(item.candidate.bookURL)/current"
    )
    _ = try await repository.applyTOCUpdate(
      bookID: item.id,
      update: .replaced(previousCount: 0, chapters: [chapter])
    )
    let library = ShelfLibrary(repository: repository)

    await library.cacheChapterContent(
      "来自另一书源的正文",
      bookID: item.id,
      chapterID: chapter.id
    )

    let reopened = try GRDBBookShelfRepository(path: path)
    let restoredBook = try await reopened.book(id: item.id)
    let restoredChapters = try await reopened.chapters(bookID: item.id)
    let content = try await reopened.chapterContent(
      bookID: item.id,
      chapterID: chapter.id
    )
    XCTAssertEqual(
      restoredBook?.candidate.sourceID,
      item.candidate.sourceID
    )
    XCTAssertEqual(restoredChapters, [chapter])
    XCTAssertEqual(content, "来自另一书源的正文")
  }

  private func temporaryDatabasePath() -> String {
    FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("sqlite")
      .path
  }

  private func candidate(
    name: String,
    suffix: String
  ) -> ShelfBookCandidate {
    ShelfBookCandidate(
      name: name,
      author: "作者",
      kind: "测试",
      lastChapter: "",
      intro: "",
      bookURL: "http://sourcelab.test/books/\(suffix)",
      coverURL: nil,
      originName: "测试源",
      sourceID: "source://test"
    )
  }
}

private enum TestFailure: Error {
  case expected
}

private actor RetryingReaderLoader: ReaderContentLoading {
  let failuresBeforeSuccess: Int
  private(set) var attemptCount = 0
  private var chapterAttempts: [ChapterID: Int] = [:]

  init(failuresBeforeSuccess: Int) {
    self.failuresBeforeSuccess = failuresBeforeSuccess
  }

  func load(
    book: ShelfBookItem,
    chapter: BookChapter,
    characterOffset: Int
  ) async throws -> ReaderDocument {
    attemptCount += 1
    chapterAttempts[chapter.id, default: 0] += 1
    if chapterAttempts[chapter.id, default: 0] <= failuresBeforeSuccess {
      throw TestFailure.expected
    }
    return ReaderDocument(
      position: ReaderPosition(
        bookID: book.id,
        chapterID: chapter.id,
        chapterIndex: chapter.index,
        characterOffset: characterOffset
      ),
      title: chapter.title,
      content: "离线正文 \(chapter.index)"
    )
  }
}

private struct UnavailableReaderLoader: ReaderContentLoading {
  func load(
    book: ShelfBookItem,
    chapter: BookChapter,
    characterOffset: Int
  ) async throws -> ReaderDocument {
    throw TestFailure.expected
  }
}
