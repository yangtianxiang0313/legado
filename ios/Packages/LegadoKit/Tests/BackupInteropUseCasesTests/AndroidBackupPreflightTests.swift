import AndroidBackupInterop
import AppUseCases
import ArchiveZIPFoundation
import BackupInteropUseCases
import Foundation
import LibraryDomain
import SourceFormat
import Testing

@Suite("AndroidBackupPreflightTests")
struct AndroidBackupPreflightTests {
  @Test func freezesEveryAndroidBackupMemberDisposition() throws {
    #expect(AndroidBackupArchive.knownAndroidMemberNames == Set([
      "bookshelf.json",
      "bookmark.json",
      "bookGroup.json",
      "bookSource.json",
      "rssSources.json",
      "rssStar.json",
      "replaceRule.json",
      "readRecord.json",
      "searchHistory.json",
      "sourceSub.json",
      "txtTocRule.json",
      "httpTTS.json",
      "keyboardAssists.json",
      "dictRule.json",
      "servers.json",
      "directLinkUploadRule.json",
      "readConfig.json",
      "shareReadConfig.json",
      "themeConfig.json",
      "config.xml",
    ]))
    #expect(AndroidBackupArchive.deferredMemberNames == [
      "directLinkUploadRule.json"
    ])
  }

  @Test func reportsSupportedAndDeferredMembersBeforeRestore() async throws {
    let archiveURL = try makeArchive([
      .init(path: "bookshelf.json", data: Data("[]".utf8)),
      .init(
        path: "directLinkUploadRule.json",
        data: Data(
          #"{"uploadUrl":"https://upload.invalid","downloadUrlRule":"$.url","summary":"test","compress":false}"#.utf8
        )
      ),
    ])
    defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }

    let repository = PreflightRestoreRepository()
    let summary = try await AndroidCoreBackupRestoreUseCase(
      repository: repository
    ).restore(from: archiveURL)

    #expect(summary.preflight.members.map(\.path) == [
      "bookshelf.json", "directLinkUploadRule.json",
    ])
    #expect(summary.preflight.members.map(\.disposition) == [
      .supported, .deferred,
    ])
    #expect(!summary.preflight.hasBlockingIssues)
    #expect(await repository.writeCount == 1)
  }

  @Test func rejectsUnknownMemberBeforeAnyRepositoryWrite() async throws {
    let archiveURL = try makeArchive([
      .init(path: "bookshelf.json", data: Data("[]".utf8)),
      .init(path: "futureDomain.json", data: Data("[]".utf8)),
    ])
    defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }
    let repository = PreflightRestoreRepository()

    do {
      _ = try await AndroidCoreBackupRestoreUseCase(
        repository: repository
      ).restore(from: archiveURL)
      Issue.record("Expected preflight rejection")
    } catch let AndroidCoreBackupRestoreError.preflightRejected(report) {
      #expect(report.members.first { $0.path == "futureDomain.json" }?.disposition == .unsafe)
      #expect(report.hasBlockingIssues)
    }
    #expect(await repository.writeCount == 0)
  }

  @Test func rejectsMalformedKnownMemberBeforeAnyRepositoryWrite() async throws {
    let archiveURL = try makeArchive([
      .init(path: "bookshelf.json", data: Data("not-json".utf8)),
    ])
    defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }
    let repository = PreflightRestoreRepository()

    do {
      _ = try await AndroidCoreBackupRestoreUseCase(
        repository: repository
      ).restore(from: archiveURL)
      Issue.record("Expected malformed payload rejection")
    } catch let AndroidCoreBackupRestoreError.preflightRejected(report) {
      #expect(report.members == [
        AndroidBackupMemberInspection(
          path: "bookshelf.json",
          uncompressedSize: 8,
          disposition: .malformed,
          reason: "invalid_payload"
        )
      ])
    }
    #expect(await repository.writeCount == 0)
  }

  private func makeArchive(
    _ members: [ArchiveZIPFoundation.Member]
  ) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    let archiveURL = directory.appendingPathComponent("backup.zip")
    try ArchiveZIPFoundation.create(members: members, at: archiveURL)
    return archiveURL
  }
}

private actor PreflightRestoreRepository: AndroidCoreBackupRestoreRepository {
  private(set) var writeCount = 0

  func restoreAndroidLibrary(
    _ plan: AndroidLibraryRestorePlan
  ) async throws -> AndroidLibraryRestoreSummary {
    writeCount += 1
    return AndroidLibraryRestoreSummary(
      bookCount: plan.books.count,
      groupCount: plan.groups.count,
      bookmarkCount: plan.bookmarks.count
    )
  }

  func restoreAndroidBookSources(_ sources: [BookSourceDraft]) async throws {
    writeCount += 1
  }

  func restoreAndroidReplacementRules(
    _ rules: [ReaderReplacementRule]
  ) async throws {
    writeCount += 1
  }

  func restoreAndroidReadRecords(_ records: [ReadRecord]) async throws {
    writeCount += 1
  }
}
