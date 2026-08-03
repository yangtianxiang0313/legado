import AndroidBackupInterop
import BackupInteropUseCases
import Foundation
import LegadoCore
import Testing

@Test func mapsAndroidLibraryWithoutCollapsingGroupMask() throws {
  let book = try #require(
    AndroidBookCodec.decodeMany(
      Data(
        #"[{"bookUrl":"https://android.invalid/book","tocUrl":"https://android.invalid/toc","origin":"https://android.invalid/source","originName":"Android Source","name":"Android Book","author":"Android Author","kind":"fiction","coverUrl":"https://android.invalid/cover","intro":"intro","customIntro":"custom intro","customTag":"favorite","charset":"GBK","type":1,"group":9,"latestChapterTitle":"Chapter Ten","latestChapterTime":1700000000000,"lastCheckCount":2,"totalChapterNum":10,"durChapterTitle":"Chapter Four","durChapterIndex":3,"durChapterPos":27,"durChapterTime":1700000000123,"wordCount":"10000","canUpdate":false,"order":6,"originOrder":2,"variable":"{\"token\":\"kept\",\"count\":3}","readConfig":{"reverseToc":true,"splitLongChapter":false},"syncTime":1700000000999}]"#
          .utf8
      )
    ).first
  )

  let restored = try #require(
    AndroidLibraryImportAdapter.plan(
      books: [book],
      groups: [],
      bookmarks: []
    ).books.first
  )

  #expect(restored.candidate.bookURL == "https://android.invalid/book")
  #expect(restored.candidate.tocURL == "https://android.invalid/toc")
  #expect(restored.candidate.sourceID == "https://android.invalid/source")
  #expect(restored.candidate.variables == ["token": "kept"])
  #expect(restored.groupMask == 9)
  #expect(restored.progress.position.chapterIndex == 3)
  #expect(restored.progress.position.characterOffset == 27)
  #expect(restored.progress.chapterTitle == "Chapter Four")
  #expect(restored.progress.updatedAtMilliseconds == 1_700_000_000_123)
  #expect(restored.chapterCount == 10)
  #expect(restored.reversesTableOfContents)
  #expect(!restored.splitsLongChapters)
  #expect(!restored.canUpdate)
  #expect(restored.customTag == "favorite")
  #expect(restored.charset == "GBK")
  #expect(restored.wordCount == "10000")
}

@Test func mapsGroupsAndKeepsBookmarkNaturalIdentity() throws {
  let group = AndroidBookGroupDTO(
    groupID: 8,
    groupName: "Android Group",
    cover: "group-cover",
    order: 4,
    enableRefresh: false,
    show: true,
    bookSort: 2
  )
  let bookmark = AndroidBookmarkDTO(
    time: 1_700_000_000_123,
    bookName: "Android Book",
    bookAuthor: "Android Author",
    chapterIndex: 3,
    chapterPosition: 27,
    chapterName: "Chapter Four",
    bookText: "selected",
    content: "context"
  )

  let plan = try AndroidLibraryImportAdapter.plan(
    books: [],
    groups: [group],
    bookmarks: [bookmark]
  )

  #expect(
    plan.groups == [
      AndroidLibraryRestoreGroup(
        id: 8,
        name: "Android Group",
        cover: "group-cover",
        order: 4,
        enablesRefresh: false,
        isShown: true,
        bookSort: 2
      )
    ])
  #expect(plan.bookmarks.first?.bookName == "Android Book")
  #expect(plan.bookmarks.first?.bookAuthor == "Android Author")
  #expect(plan.bookmarks.first?.chapterIndex == 3)
  #expect(plan.bookmarks.first?.chapterPosition == 27)
}

@Test func readsACompleteAndroidArchiveIntoOneRestorePlan() throws {
  let book = AndroidBookDTO(
    bookURL: "https://android.invalid/book",
    origin: "https://android.invalid/source",
    originName: "Android Source",
    name: "Android Book",
    author: "Android Author",
    group: 3,
    currentChapterIndex: 2,
    currentChapterPosition: 11
  )
  let archiveURL = temporaryArchiveURL()
  defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }
  try AndroidBackupArchive.write(
    .init(
      books: [book],
      bookGroups: [.init(groupID: 1, groupName: "One")],
      bookmarks: [
        .init(
          time: 7,
          bookName: "Android Book",
          bookAuthor: "Android Author",
          chapterIndex: 2,
          chapterPosition: 11,
          chapterName: "Three",
          bookText: "text",
          content: "context"
        )
      ]
    ),
    to: archiveURL
  )

  let plan = try AndroidLibraryImportAdapter.plan(from: archiveURL)

  #expect(plan.books.count == 1)
  #expect(plan.books.first?.groupMask == 3)
  #expect(plan.groups.map(\.id) == [1])
  #expect(plan.bookmarks.map(\.time) == [7])
}

@Test func rejectsBookWithoutAndroidPrimaryKey() throws {
  let book = try #require(
    AndroidBookCodec.decodeMany(Data(#"[{"name":"Missing URL"}]"#.utf8)).first
  )

  #expect(throws: AndroidLibraryImportError.emptyBookURL(index: 0)) {
    try AndroidLibraryImportAdapter.plan(
      books: [book],
      groups: [],
      bookmarks: []
    )
  }
}

private func temporaryArchiveURL() -> URL {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try? FileManager.default.createDirectory(
    at: directory,
    withIntermediateDirectories: true
  )
  return directory.appendingPathComponent(AndroidBackupArchive.fileName)
}
