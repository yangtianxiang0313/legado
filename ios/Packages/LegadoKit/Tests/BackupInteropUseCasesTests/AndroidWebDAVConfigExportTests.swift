import AndroidBackupInterop
import AppUseCases
import BackupInteropUseCases
import Foundation
import LibraryDomain
import Testing

@Suite("AndroidWebDAVConfigExportTests")
struct AndroidWebDAVConfigExportTests {
  @Test func exportsAndroidReadableConfigXMLWithEncryptedPassword() async throws {
    let useCase = AndroidLibraryBackupUseCase(
      repository: WebDAVConfigExportRepositoryStub()
    )
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let archiveURL = directory.appendingPathComponent("backup.zip")

    let summary = try await useCase.export(
      to: archiveURL,
      bookSources: [],
      replacementRules: [],
      readerPreferences: nil,
      webDAVConfiguration: AndroidWebDAVBackupExportInput(
        serverAddress: "https://dav.example/root",
        username: "reader",
        password: "webdav-secret",
        directoryName: "legado/shared",
        backupPassword: "backup-pass",
        syncBookProgress: false,
        webDAVDeviceName: "iPhone",
        onlyLatestBackup: false
      )
    )
    let restored = try AndroidBackupArchive.readWebDAVBackupConfiguration(
      from: archiveURL
    )
    let configuration = try #require(restored)

    #expect(summary.webDAVConfigurationCount == 1)
    #expect(configuration.serverAddress == "https://dav.example/root")
    #expect(configuration.username == "reader")
    #expect(configuration.directoryName == "legado/shared")
    #expect(configuration.syncBookProgress == false)
    #expect(configuration.webDAVDeviceName == "iPhone")
    #expect(configuration.onlyLatestBackup == false)
    #expect(configuration.unresolvedPasswordPayload == "0LSuhOm3EXMTTUpsnaZ4lg==")
    #expect(
      try AndroidBackupAES.decryptBase64(
        configuration.unresolvedPasswordPayload ?? "",
        backupPassword: "backup-pass"
      ) == "webdav-secret"
    )
  }

  @Test func configuredWebDAVSupportsAndroidDefaultEmptyPassword() async throws {
    let useCase = AndroidLibraryBackupUseCase(
      repository: WebDAVConfigExportRepositoryStub()
    )
    let archiveURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)

    let summary = try await useCase.export(
      to: archiveURL,
      bookSources: [],
      replacementRules: [],
      readerPreferences: nil,
      webDAVConfiguration: AndroidWebDAVBackupExportInput(
        serverAddress: "https://dav.example/root",
        username: "reader",
        password: "secret",
        directoryName: "legado",
        backupPassword: ""
      )
    )
    let restored = try AndroidBackupArchive.readWebDAVBackupConfiguration(
      from: archiveURL
    )
    let configuration = try #require(restored)

    #expect(summary.webDAVConfigurationCount == 1)
    #expect(
      try AndroidBackupAES.decryptBase64(
        configuration.unresolvedPasswordPayload ?? "",
        backupPassword: ""
      ) == "secret"
    )
  }
}

private struct WebDAVConfigExportRepositoryStub:
  AndroidLibraryBackupRepository
{
  func androidLibraryBackupPlan() async throws -> AndroidLibraryRestorePlan {
    AndroidLibraryRestorePlan(books: [], groups: [], bookmarks: [])
  }
}

private extension WebDAVConfigExportRepositoryStub {
  func localTextTOCRules() async throws -> [LocalTextTOCRule] { [] }
  func androidReaderConfigBundle() async throws -> AndroidReaderConfigBundle? {
    nil
  }
  func dictionaryRules() async throws -> [DictionaryRule] { [] }
}
