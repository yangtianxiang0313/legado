import AndroidBackupInterop
import AppUseCases
import BackupInteropUseCases
import Foundation
import LibraryDomain
import Testing

@Suite("AndroidCoreBackupRestoreUseCaseTests")
struct AndroidCoreBackupRestoreUseCaseTests {
  @Test func restoresEveryPresentCoreDomain() async throws {
    let repository = CoreRestoreRepositoryStub()
    let useCase = AndroidCoreBackupRestoreUseCase(repository: repository)
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let archiveURL = directory.appendingPathComponent("backup.zip")
    let source = try #require(
      AndroidBackupArchive.decodeBookSources(
        Data(
          #"[{"bookSourceUrl":"https://android.invalid/source","bookSourceName":"Android Source","searchUrl":"https://android.invalid/search?key={{key}}","ruleSearch":{"bookList":"$.books[*]"},"enabled":false}]"#.utf8
        )
      ).first
    )
    try AndroidBackupArchive.write(
      AndroidBackupContents(
        bookSources: [source],
        replacementRules: [
          AndroidReplaceRuleDTO(
            id: 42,
            name: "去广告",
            pattern: "ad",
            replacement: "",
            order: 3
          )
        ],
        readRecords: [
          AndroidReadRecordDTO(
            deviceID: "android-device",
            bookName: "Android Book",
            readTime: 3_600,
            lastRead: 1_700_000_000_789
          )
        ]
      ),
      to: archiveURL
    )

    let summary = try await useCase.restore(from: archiveURL)
    let snapshot = await repository.snapshot()

    #expect(summary.bookCount == 0)
    #expect(summary.groupCount == 0)
    #expect(summary.bookmarkCount == 0)
    #expect(summary.bookSourceCount == 1)
    #expect(summary.replacementRuleCount == 1)
    #expect(summary.readRecordCount == 1)
    #expect(summary.preflight.members.map(\.path) == [
      "bookSource.json", "readRecord.json", "replaceRule.json",
    ])
    #expect(summary.preflight.members.allSatisfy {
      $0.disposition == .supported
    })
    #expect(snapshot.sources.first?.sourceURL == "https://android.invalid/source")
    #expect(snapshot.rules.first?.id == "42")
    #expect(snapshot.rules.first?.name == "去广告")
    #expect(snapshot.rules.first?.order == 3)
    #expect(snapshot.records.first?.deviceID == "android-device")
    #expect(snapshot.records.first?.readTime == 3_600)
  }

}

private actor CoreRestoreRepositoryStub: AndroidCoreBackupRestoreRepository {
  private var sources: [BookSourceDraft] = []
  private var rules: [ReaderReplacementRule] = []
  private var records: [ReadRecord] = []

  func restoreAndroidLibrary(
    _ plan: AndroidLibraryRestorePlan
  ) async throws -> AndroidLibraryRestoreSummary {
    AndroidLibraryRestoreSummary(
      bookCount: plan.books.count,
      groupCount: plan.groups.count,
      bookmarkCount: plan.bookmarks.count
    )
  }

  func restoreAndroidBookSources(_ sources: [BookSourceDraft]) async throws {
    self.sources = sources
  }

  func restoreAndroidReplacementRules(
    _ rules: [ReaderReplacementRule]
  ) async throws {
    self.rules = rules
  }

  func restoreAndroidReadRecords(_ records: [ReadRecord]) async throws {
    self.records = records
  }

  func snapshot() -> (
    sources: [BookSourceDraft],
    rules: [ReaderReplacementRule],
    records: [ReadRecord]
  ) {
    (sources, rules, records)
  }
}
