import AndroidBackupInterop
import AppUseCases
import BackupInteropUseCases
import Foundation
import LibraryDomain
import Testing

@Suite("DirectLinkUploadRulePersistenceTests")
struct DirectLinkUploadRulePersistenceTests {
  @Test func coreRestoreAndFullBackupRoundTripRule() async throws {
    let repository = DirectLinkRuleRepositoryStub()
    let rule = DirectLinkUploadRule(
      uploadURL: "https://upload.example/{{fileName}}",
      downloadURLRule: "$.data.url",
      summary: "对象存储",
      compress: true,
      unknownFields: ["futureHeader": .string("x-token")]
    )
    let document = try #require(
      AndroidDirectLinkUploadRuleInteropAdapter.backupDocument(rule)
    )
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let androidArchive = directory.appendingPathComponent("android.zip")
    try AndroidBackupArchive.write(
      AndroidBackupContents(directLinkUploadRule: document),
      to: androidArchive
    )

    let restoreSummary = try await AndroidCoreBackupRestoreUseCase(
      repository: repository
    ).restore(from: androidArchive)
    #expect(try await repository.directLinkUploadRule() == rule)
    #expect(
      restoreSummary.preflight.members.first?.disposition == .supported
    )

    let iosArchive = directory.appendingPathComponent("ios.zip")
    _ = try await AndroidLibraryBackupUseCase(
      repository: repository
    ).export(
      to: iosArchive,
      bookSources: [],
      replacementRules: []
    )
    let roundTripped = try AndroidBackupArchive.readDirectLinkUploadRule(
      from: iosArchive
    )
    #expect(roundTripped == document)
  }
}

private actor DirectLinkRuleRepositoryStub:
  AndroidCoreBackupRestoreRepository, AndroidLibraryBackupRepository
{
  private var rule: DirectLinkUploadRule?

  func restoreAndroidLibrary(
    _ plan: AndroidLibraryRestorePlan
  ) async throws -> AndroidLibraryRestoreSummary {
    AndroidLibraryRestoreSummary(
      bookCount: plan.books.count,
      groupCount: plan.groups.count,
      bookmarkCount: plan.bookmarks.count
    )
  }

  func restoreAndroidBookSources(
    _ sources: [BookSourceDraft]
  ) async throws {}

  func restoreAndroidReplacementRules(
    _ rules: [ReaderReplacementRule]
  ) async throws {}

  func restoreAndroidReadRecords(
    _ records: [ReadRecord]
  ) async throws {}

  func restoreAndroidDirectLinkUploadRule(
    _ value: DirectLinkUploadRule
  ) async throws {
    rule = value
  }

  func directLinkUploadRule() async throws -> DirectLinkUploadRule? { rule }

  func androidLibraryBackupPlan() async throws -> AndroidLibraryRestorePlan {
    AndroidLibraryRestorePlan(books: [], groups: [], bookmarks: [])
  }
}
