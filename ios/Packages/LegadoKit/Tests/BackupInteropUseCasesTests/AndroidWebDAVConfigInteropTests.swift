import AndroidBackupInterop
import AppUseCases
import BackupInteropUseCases
import Foundation
import LibraryDomain
import Testing

@Suite("AndroidWebDAVConfigAppRestoreTests")
struct AndroidWebDAVConfigAppRestoreTests {
  @Test func coreRestoreResolvesSettingsAndCredential() async throws {
    let repository = WebDAVConfigRestoreRepositoryStub()
    let useCase = AndroidCoreBackupRestoreUseCase(repository: repository)
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let archiveURL = directory.appendingPathComponent("backup.zip")
    try AndroidBackupArchive.write(
      AndroidBackupContents(
        sharedPreferences: AndroidSharedPreferencesDocument(values: [
          AndroidWebDAVBackupConfiguration.serverAddressKey:
            .string("https://dav.example/root"),
          AndroidWebDAVBackupConfiguration.usernameKey: .string("reader"),
          AndroidWebDAVBackupConfiguration.passwordKey:
            .string("0LSuhOm3EXMTTUpsnaZ4lg=="),
          AndroidWebDAVBackupConfiguration.directoryNameKey:
            .string("shared-books"),
          AndroidWebDAVBackupConfiguration.syncBookProgressKey:
            .boolean(false),
          AndroidWebDAVBackupConfiguration.webDAVDeviceNameKey:
            .string("Pixel"),
          AndroidWebDAVBackupConfiguration.onlyLatestBackupKey:
            .boolean(false),
        ])
      ),
      to: archiveURL
    )

    let summary = try await useCase.restore(
      from: archiveURL,
      backupPassword: "backup-pass"
    )
    let plan = try #require(await repository.webDAVPlan())

    #expect(summary.webDAVConfigurationCount == 1)
    #expect(plan.settings.serverAddress == "https://dav.example/root")
    #expect(plan.settings.directoryName == "shared-books")
    #expect(plan.settings.syncBookProgress == false)
    #expect(plan.settings.webDAVDeviceName == "Pixel")
    #expect(plan.settings.onlyLatestBackup == false)
    #expect(
      plan.credential
        == .resolved(
          username: "reader",
          password: "webdav-secret"
        )
    )
  }

  @Test func missingOrWrongPasswordFailsBeforeRepositoryMutation() async throws {
    let repository = WebDAVConfigRestoreRepositoryStub()
    let useCase = AndroidCoreBackupRestoreUseCase(repository: repository)
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let archiveURL = directory.appendingPathComponent("backup.zip")
    try AndroidBackupArchive.write(
      AndroidBackupContents(
        sharedPreferences: AndroidSharedPreferencesDocument(values: [
          AndroidWebDAVBackupConfiguration.passwordKey:
            .string("0LSuhOm3EXMTTUpsnaZ4lg==")
        ])
      ),
      to: archiveURL
    )

    await #expect(throws: AndroidCoreBackupRestoreError.backupPasswordRequired) {
      try await useCase.restore(from: archiveURL)
    }
    await #expect(throws: AndroidCoreBackupRestoreError.invalidBackupPassword) {
      try await useCase.restore(
        from: archiveURL,
        backupPassword: "wrong"
      )
    }
    #expect(await repository.webDAVPlan() == nil)
    #expect(await repository.libraryRestoreCount() == 0)
  }
}

private actor WebDAVConfigRestoreRepositoryStub:
  AndroidCoreBackupRestoreRepository
{
  private var plan: AndroidWebDAVConfigurationImportPlan?
  private var libraryRestores = 0

  func restoreAndroidLibrary(
    _ plan: AndroidLibraryRestorePlan
  ) async throws -> AndroidLibraryRestoreSummary {
    libraryRestores += 1
    return AndroidLibraryRestoreSummary(
      bookCount: 0,
      groupCount: 0,
      bookmarkCount: 0
    )
  }

  func restoreAndroidBookSources(_ sources: [BookSourceDraft]) async throws {}

  func restoreAndroidReplacementRules(
    _ rules: [ReaderReplacementRule]
  ) async throws {}

  func restoreAndroidReadRecords(_ records: [ReadRecord]) async throws {}

  func restoreAndroidWebDAVConfiguration(
    _ plan: AndroidWebDAVConfigurationImportPlan
  ) async throws {
    self.plan = plan
  }

  func webDAVPlan() -> AndroidWebDAVConfigurationImportPlan? { plan }
  func libraryRestoreCount() -> Int { libraryRestores }
}

private extension WebDAVConfigRestoreRepositoryStub {
  func restoreAndroidLocalTextTOCRules(
    _ values: [LocalTextTOCRule]
  ) async throws {}
  func restoreAndroidReaderConfigBundle(
    _ bundle: AndroidReaderConfigBundle
  ) async throws {}
  func restoreAndroidDictionaryRules(
    _ values: [DictionaryRule]
  ) async throws {}
}
