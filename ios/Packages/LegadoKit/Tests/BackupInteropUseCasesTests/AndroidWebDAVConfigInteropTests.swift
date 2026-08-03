import AndroidBackupInterop
import AppUseCases
import BackupInteropUseCases
import Foundation
import LibraryDomain
import Testing

@Suite("AndroidWebDAVConfigInteropTests")
struct AndroidWebDAVConfigRestoreTests {
  @Test func coreRestoreEmitsNonSecretSettingsAndUnresolvedCredential() async throws {
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
            .string("android-encrypted-payload"),
          AndroidWebDAVBackupConfiguration.directoryNameKey:
            .string("shared-books"),
        ])
      ),
      to: archiveURL
    )

    let summary = try await useCase.restore(from: archiveURL)
    let plan = try #require(await repository.webDAVPlan())

    #expect(summary.webDAVConfigurationCount == 1)
    #expect(plan.settings.serverAddress == "https://dav.example/root")
    #expect(plan.settings.directoryName == "shared-books")
    #expect(
      plan.credential
        == .unresolvedAndroidBackupPayload(
          username: "reader",
          payload: "android-encrypted-payload"
        )
    )
  }
}

private actor WebDAVConfigRestoreRepositoryStub:
  AndroidCoreBackupRestoreRepository
{
  private var plan: AndroidWebDAVConfigurationImportPlan?

  func restoreAndroidLibrary(
    _ plan: AndroidLibraryRestorePlan
  ) async throws -> AndroidLibraryRestoreSummary {
    AndroidLibraryRestoreSummary(bookCount: 0, groupCount: 0, bookmarkCount: 0)
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
}
