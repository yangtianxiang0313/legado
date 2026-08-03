import AppUseCases
import BackupInteropUseCases
import Foundation
import IntegrationKit
import ReaderCore
import Testing

@Suite("WebDAVAutomaticBackupTests")
struct WebDAVAutomaticBackupTests {
  private let now = Date(timeIntervalSince1970: 1_775_433_600)

  @Test func strictAndroidDayBoundaryIsNotDue() async throws {
    let transfer = AutomaticBackupTransfer(list: .loaded([]))
    let exporter = AutomaticBackupExporter()
    let useCase = makeUseCase(transfer: transfer, exporter: exporter)

    let result = await useCase.automaticBackup(
      configuration: try configuration(),
      now: now,
      lastBackupMilliseconds: milliseconds(now) - 86_400_000,
      deviceName: "iPhone",
      bookSources: [],
      replacementRules: []
    )

    #expect(result == .notDue)
    #expect(await transfer.listCallCount == 0)
    #expect(await exporter.callCount == 0)
  }

  @Test func existingDailyDeviceBackupAdvancesCheckpointWithoutUpload() async throws {
    let expectedName = "backup2026-04-06-iPhone.zip"
    let transfer = AutomaticBackupTransfer(
      list: .loaded([
        WebDAVBackupFile(
          name: expectedName,
          size: 10,
          lastModifiedMilliseconds: milliseconds(now) - 100
        )
      ])
    )
    let exporter = AutomaticBackupExporter()
    let useCase = makeUseCase(transfer: transfer, exporter: exporter)

    let result = await useCase.automaticBackup(
      configuration: try configuration(),
      now: now,
      lastBackupMilliseconds: milliseconds(now) - 86_400_001,
      deviceName: " iPhone ",
      timeZone: TimeZone(secondsFromGMT: 0)!,
      bookSources: [],
      replacementRules: []
    )

    #expect(
      result == .remoteAlreadyExists(
        fileName: expectedName,
        checkpointMilliseconds: milliseconds(now)
      )
    )
    #expect(await exporter.callCount == 0)
    #expect(await transfer.uploadedFileName == nil)
  }

  @Test func dueBackupUploadsAndroidArchiveWithDailyDeviceName() async throws {
    let transfer = AutomaticBackupTransfer(list: .loaded([]))
    let exporter = AutomaticBackupExporter()
    let useCase = makeUseCase(transfer: transfer, exporter: exporter)

    let result = await useCase.automaticBackup(
      configuration: try configuration(),
      now: now,
      lastBackupMilliseconds: 0,
      deviceName: "iPhone",
      timeZone: TimeZone(secondsFromGMT: 0)!,
      bookSources: [],
      replacementRules: []
    )

    let expectedSummary = AndroidLibraryBackupSummary(
      bookCount: 1,
      groupCount: 0,
      bookmarkCount: 0
    )
    #expect(
      result == .uploaded(
        fileName: "backup2026-04-06-iPhone.zip",
        checkpointMilliseconds: milliseconds(now),
        summary: expectedSummary
      )
    )
    #expect(await exporter.callCount == 1)
    #expect(
      await transfer.uploadedFileName
        == "backup2026-04-06-iPhone.zip"
    )
  }

  @Test func listFailureDoesNotCreateOrUploadArchive() async throws {
    let transfer = AutomaticBackupTransfer(
      list: .failed(.authenticationRejected)
    )
    let exporter = AutomaticBackupExporter()
    let useCase = makeUseCase(transfer: transfer, exporter: exporter)

    let result = await useCase.automaticBackup(
      configuration: try configuration(),
      now: now,
      lastBackupMilliseconds: 0,
      deviceName: "iPhone",
      bookSources: [],
      replacementRules: []
    )

    #expect(result == .failed(.list(.authenticationRejected)))
    #expect(await exporter.callCount == 0)
    #expect(await transfer.uploadedFileName == nil)
  }

  private func makeUseCase(
    transfer: AutomaticBackupTransfer,
    exporter: AutomaticBackupExporter
  ) -> WebDAVBackupSyncUseCase {
    WebDAVBackupSyncUseCase(
      transfer: transfer,
      exporter: exporter,
      restorer: AutomaticBackupRestorer()
    )
  }

  private func configuration() throws -> WebDAVConnectionConfiguration {
    WebDAVConnectionConfiguration(
      serverURL: try #require(
        WebDAVServerURL(rawValue: "https://dav.example.test/dav")
      ),
      directoryName: "legado",
      credentialReference: WebDAVCredentialReference("credential")
    )
  }

  private func milliseconds(_ date: Date) -> Int64 {
    Int64(date.timeIntervalSince1970 * 1_000)
  }
}

private actor AutomaticBackupTransfer: WebDAVBackupTransferring {
  let list: WebDAVBackupListResult
  private(set) var listCallCount = 0
  private(set) var uploadedFileName: String?

  init(list: WebDAVBackupListResult) { self.list = list }

  func listBackups(
    configuration: WebDAVConnectionConfiguration
  ) async -> WebDAVBackupListResult {
    listCallCount += 1
    return list
  }

  func uploadBackup(
    configuration: WebDAVConnectionConfiguration,
    fileName: String,
    data: Data
  ) async -> WebDAVBackupUploadResult {
    uploadedFileName = fileName
    return .uploaded
  }

  func downloadBackup(
    configuration: WebDAVConnectionConfiguration,
    fileName: String
  ) async -> WebDAVBackupDownloadResult {
    .failed(.notFound)
  }
}

private actor AutomaticBackupExporter: AndroidCoreBackupExporting {
  private(set) var callCount = 0

  func export(
    to archiveURL: URL,
    bookSources: [BookSourceDraft],
    replacementRules: [ReaderReplacementRule],
    readerPreferences: ReaderPreferences?
  ) async throws -> AndroidLibraryBackupSummary {
    callCount += 1
    try Data([0x50, 0x4b]).write(to: archiveURL)
    return AndroidLibraryBackupSummary(
      bookCount: 1,
      groupCount: 0,
      bookmarkCount: 0
    )
  }
}

private struct AutomaticBackupRestorer: AndroidCoreBackupRestoring {
  func restore(
    from archiveURL: URL
  ) async throws -> AndroidCoreBackupRestoreSummary {
    fatalError("restore is not part of automatic backup")
  }
}
