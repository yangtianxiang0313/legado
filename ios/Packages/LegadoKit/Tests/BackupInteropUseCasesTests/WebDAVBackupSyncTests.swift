import AppUseCases
import BackupInteropUseCases
import Foundation
import IntegrationKit
import ReaderCore
import XCTest

final class WebDAVBackupSyncTests: XCTestCase {
  func testUploadsExactExportedAndroidArchive() async throws {
    let archive = Data([0x50, 0x4B, 0x03, 0x04])
    let transfer = BackupTransferDouble(upload: .uploaded)
    let summary = backupSummary(bookCount: 2)
    let useCase = WebDAVBackupSyncUseCase(
      transfer: transfer,
      exporter: BackupExporterDouble(data: archive, summary: summary),
      restorer: BackupRestorerDouble(summary: restoreSummary(bookCount: 0))
    )

    let result = await useCase.upload(
      configuration: try configuration(),
      fileName: "backup2026-08-04-iPhone.zip",
      bookSources: [],
      replacementRules: []
    )

    XCTAssertEqual(
      .uploaded(fileName: "backup2026-08-04-iPhone.zip", summary: summary),
      result
    )
    let uploaded = await transfer.uploadedPayload
    XCTAssertEqual(archive, uploaded?.data)
    XCTAssertEqual("backup2026-08-04-iPhone.zip", uploaded?.fileName)
  }

  func testUploadFailureRemainsStructured() async throws {
    let transfer = BackupTransferDouble(
      upload: .failed(.authenticationRejected)
    )
    let useCase = WebDAVBackupSyncUseCase(
      transfer: transfer,
      exporter: BackupExporterDouble(
        data: Data([0x50, 0x4B]),
        summary: backupSummary(bookCount: 1)
      ),
      restorer: BackupRestorerDouble(summary: restoreSummary(bookCount: 0))
    )

    let result = await useCase.upload(
      configuration: try configuration(),
      fileName: "backup2026-08-04.zip",
      bookSources: [],
      replacementRules: []
    )
    XCTAssertEqual(.failed(.upload(.authenticationRejected)), result)
  }

  func testDownloadsBeforeInvokingRestore() async throws {
    let archive = Data([0x50, 0x4B, 0x03, 0x04])
    let transfer = BackupTransferDouble(download: .downloaded(archive))
    let expected = restoreSummary(bookCount: 3)
    let restorer = BackupRestorerDouble(summary: expected)
    let useCase = WebDAVBackupSyncUseCase(
      transfer: transfer,
      exporter: BackupExporterDouble(
        data: Data(),
        summary: backupSummary(bookCount: 0)
      ),
      restorer: restorer
    )

    let result = await useCase.restore(
      configuration: try configuration(),
      fileName: "backup2026-08-04.zip",
      backupPassword: "correct-password"
    )

    XCTAssertEqual(.restored(expected), result)
    let restoredData = await restorer.restoredData
    XCTAssertEqual(archive, restoredData)
    let restoredPassword = await restorer.restoredPassword
    XCTAssertEqual("correct-password", restoredPassword)
  }

  func testClassifiesAndroidBackupPasswordFailures() async throws {
    for (error, expected) in [
      (
        AndroidCoreBackupRestoreError.backupPasswordRequired,
        WebDAVBackupSyncFailure.backupPasswordRequired
      ),
      (
        AndroidCoreBackupRestoreError.invalidBackupPassword,
        WebDAVBackupSyncFailure.invalidBackupPassword
      ),
    ] {
      let useCase = WebDAVBackupSyncUseCase(
        transfer: BackupTransferDouble(
          download: .downloaded(Data([0x50, 0x4B]))
        ),
        exporter: BackupExporterDouble(
          data: Data(),
          summary: backupSummary(bookCount: 0)
        ),
        restorer: BackupRestorerDouble(
          summary: restoreSummary(bookCount: 0),
          error: error
        )
      )

      let result = await useCase.restore(
        configuration: try configuration(),
        fileName: "backup-encrypted.zip"
      )
      XCTAssertEqual(.failed(expected), result)
    }
  }

  func testRemoteDownloadFailureNeverInvokesRestore() async throws {
    let transfer = BackupTransferDouble(download: .failed(.notFound))
    let restorer = BackupRestorerDouble(summary: restoreSummary(bookCount: 0))
    let useCase = WebDAVBackupSyncUseCase(
      transfer: transfer,
      exporter: BackupExporterDouble(
        data: Data(),
        summary: backupSummary(bookCount: 0)
      ),
      restorer: restorer
    )

    let result = await useCase.restore(
      configuration: try configuration(),
      fileName: "backup2026-08-04.zip"
    )

    XCTAssertEqual(.failed(.download(.notFound)), result)
    let restoredData = await restorer.restoredData
    XCTAssertNil(restoredData)
  }

  func testGeneratesAndroidCompatibleDailyName() {
    let date = Calendar(identifier: .gregorian).date(
      from: DateComponents(
        timeZone: TimeZone(secondsFromGMT: 0),
        year: 2026,
        month: 8,
        day: 4
      )
    )!
    XCTAssertEqual(
      "backup2026-08-04-iPhone.zip",
      WebDAVBackupSyncUseCase.androidFileName(
        date: date,
        deviceName: " iPhone ",
        timeZone: TimeZone(secondsFromGMT: 0)!
      )
    )
  }

  private func configuration() throws -> WebDAVConnectionConfiguration {
    WebDAVConnectionConfiguration(
      serverURL: try XCTUnwrap(
        WebDAVServerURL(rawValue: "https://dav.example.test/dav")
      ),
      directoryName: "legado",
      credentialReference: WebDAVCredentialReference("credential")
    )
  }

  private func backupSummary(bookCount: Int) -> AndroidLibraryBackupSummary {
    AndroidLibraryBackupSummary(
      bookCount: bookCount,
      groupCount: 0,
      bookmarkCount: 0
    )
  }

  private func restoreSummary(bookCount: Int) -> AndroidCoreBackupRestoreSummary {
    AndroidCoreBackupRestoreSummary(
      bookCount: bookCount,
      groupCount: 0,
      bookmarkCount: 0,
      bookSourceCount: 0,
      replacementRuleCount: 0
    )
  }
}

private actor BackupTransferDouble: WebDAVBackupTransferring {
  struct Payload: Sendable {
    let fileName: String
    let data: Data
  }

  private let list: WebDAVBackupListResult
  private let upload: WebDAVBackupUploadResult
  private let download: WebDAVBackupDownloadResult
  private(set) var uploadedPayload: Payload?

  init(
    list: WebDAVBackupListResult = .loaded([]),
    upload: WebDAVBackupUploadResult = .uploaded,
    download: WebDAVBackupDownloadResult = .failed(.notFound)
  ) {
    self.list = list
    self.upload = upload
    self.download = download
  }

  func listBackups(
    configuration: WebDAVConnectionConfiguration
  ) async -> WebDAVBackupListResult {
    list
  }

  func uploadBackup(
    configuration: WebDAVConnectionConfiguration,
    fileName: String,
    data: Data
  ) async -> WebDAVBackupUploadResult {
    uploadedPayload = Payload(fileName: fileName, data: data)
    return upload
  }

  func downloadBackup(
    configuration: WebDAVConnectionConfiguration,
    fileName: String
  ) async -> WebDAVBackupDownloadResult {
    download
  }
}

private struct BackupExporterDouble: AndroidCoreBackupExporting {
  let data: Data
  let summary: AndroidLibraryBackupSummary

  func export(
    to archiveURL: URL,
    bookSources: [BookSourceDraft],
    replacementRules: [ReaderReplacementRule],
    readerPreferences: ReaderPreferences?,
    context: AndroidBackupExportContext
  ) async throws -> AndroidLibraryBackupSummary {
    try data.write(to: archiveURL)
    return summary
  }
}

private actor BackupRestorerDouble: AndroidCoreBackupRestoring {
  let summary: AndroidCoreBackupRestoreSummary
  let error: AndroidCoreBackupRestoreError?
  private(set) var restoredData: Data?
  private(set) var restoredPassword: String?

  init(
    summary: AndroidCoreBackupRestoreSummary,
    error: AndroidCoreBackupRestoreError? = nil
  ) {
    self.summary = summary
    self.error = error
  }

  func restore(from archiveURL: URL, backupPassword: String?) async throws
    -> AndroidCoreBackupRestoreSummary
  {
    restoredData = try Data(contentsOf: archiveURL)
    restoredPassword = backupPassword
    if let error { throw error }
    return summary
  }
}
