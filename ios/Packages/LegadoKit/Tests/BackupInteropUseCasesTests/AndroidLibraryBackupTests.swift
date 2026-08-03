import AndroidBackupInterop
import AppUseCases
import BackupInteropUseCases
import Foundation
import LibraryDomain
import Testing

@Suite("AndroidLibraryBackupUseCaseTests")
struct AndroidLibraryBackupUseCaseTests {
  @Test func writesArchiveThatImportsBackToTheSameLibraryPlan() async throws {
    let plan = fixturePlan()
    let repository = BackupRepositoryStub(plan: plan)
    let useCase = AndroidLibraryBackupUseCase(repository: repository)
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let archiveURL = directory.appendingPathComponent("backup.zip")

    let summary = try await useCase.export(
      to: archiveURL,
      bookSources: [
        BookSourceDraft(
          sourceURL: "https://ios.invalid/source",
          name: "iOS Source",
          searchURL: "https://ios.invalid/search?key={{key}}",
          searchRule: "$.books[*]"
        )
      ],
      replacementRules: [
        ReaderReplacementRule(
          id: "ios-rule",
          name: "去广告",
          pattern: "ad",
          replacement: "",
          order: 3
        )
      ]
    )
    let restored = try AndroidLibraryImportAdapter.plan(from: archiveURL)
    let sources = try AndroidBackupArchive.readBookSources(from: archiveURL)
    let rules = try AndroidBackupArchive.readReplacementRules(from: archiveURL)

    #expect(
      summary == AndroidLibraryBackupSummary(
        bookCount: 1,
        groupCount: 1,
        bookmarkCount: 1,
        bookSourceCount: 1,
        replacementRuleCount: 1
      )
    )
    #expect(restored == plan)
    #expect(sources.first?.bookSourceUrl == .value("https://ios.invalid/source"))
    #expect(rules.first?.name == .value("去广告"))
    #expect(rules.first?.order == .value(3))
  }

  private func fixturePlan() -> AndroidLibraryRestorePlan {
    AndroidLibraryRestorePlan(
      books: [
        AndroidLibraryRestoreBook(
          candidate: ShelfBookCandidate(
            name: "iOS Book",
            author: "iOS Author",
            kind: "fiction",
            lastChapter: "Chapter Ten",
            intro: "intro",
            bookURL: "https://ios.invalid/book",
            tocURL: "https://ios.invalid/toc",
            coverURL: "https://ios.invalid/cover",
            customIntro: "custom intro",
            originName: "iOS Source",
            sourceID: "https://ios.invalid/source",
            variables: ["token": "kept"]
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
      ],
      groups: [
        AndroidLibraryRestoreGroup(
          id: 8,
          name: "工作",
          cover: "group-cover",
          order: 4,
          enablesRefresh: false,
          isShown: true,
          bookSort: 2
        )
      ],
      bookmarks: [
        Bookmark(
          time: 1_700_000_000_123,
          bookName: "iOS Book",
          bookAuthor: "iOS Author",
          chapterIndex: 3,
          chapterPosition: 27,
          chapterName: "Chapter Four",
          bookText: "selected",
          content: "context"
        )
      ]
    )
  }
}

private actor BackupRepositoryStub: AndroidLibraryBackupRepository {
  let plan: AndroidLibraryRestorePlan

  init(plan: AndroidLibraryRestorePlan) {
    self.plan = plan
  }

  func androidLibraryBackupPlan() async throws -> AndroidLibraryRestorePlan {
    plan
  }
}
