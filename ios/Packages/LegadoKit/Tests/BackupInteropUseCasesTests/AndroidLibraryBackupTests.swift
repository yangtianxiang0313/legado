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

    let summary = try await useCase.export(to: archiveURL)
    let restored = try AndroidLibraryImportAdapter.plan(from: archiveURL)

    #expect(
      summary == AndroidLibraryBackupSummary(
        bookCount: 1, groupCount: 1, bookmarkCount: 1
      )
    )
    #expect(restored == plan)
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
