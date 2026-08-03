import AndroidBackupInterop
import AppUseCases
import BackupInteropUseCases
import Foundation
import IntegrationKit
import LibraryDomain
import Testing

@Suite("WebDAVServerProfilePersistenceTests")
struct WebDAVServerProfilePersistenceUseCaseTests {
  @Test func restoreSavesOnlyCredentialReferencesInRepository() async throws {
    let repository = ProfileRepositoryStub()
    let vault = ProfileCredentialVaultStub()
    let useCase = AndroidWebDAVServerProfileRestoreUseCase(
      repository: repository,
      vault: vault
    )
    let plan = AndroidServerProfileImportPlan(
      entries: [
        .webDAV(
          AndroidWebDAVServerProfile(
            id: 7,
            name: "主书库",
            url: "https://dav.example/books",
            username: "reader",
            password: "secret",
            sortNumber: 10
          )
        )
      ],
      selectedID: 7
    )

    try await useCase.restore(plan)

    let profiles = try await repository.webDAVServerProfiles()
    #expect(
      profiles == [
        WebDAVServerProfile(
          id: 7,
          name: "主书库",
          serverAddress: "https://dav.example/books",
          sortNumber: 10,
          credentialReference: .init("webdav.server.7")
        )
      ]
    )
    #expect(try await repository.selectedWebDAVServerProfileID() == 7)
    #expect(
      await vault.credential(for: .init("webdav.server.7"))
        == AndroidWebDAVServerCredential(
          username: "reader",
          password: "secret"
        )
    )
  }

  @Test func databaseFailureRollsBackOverwrittenAndNewCredentials() async throws {
    let oldProfile = WebDAVServerProfile(
      id: 7,
      name: "旧书库",
      serverAddress: "https://old.example/books",
      sortNumber: 1,
      credentialReference: .init("webdav.server.7")
    )
    let repository = ProfileRepositoryStub(
      profiles: [oldProfile],
      selectedID: 7,
      failsNextReplace: true
    )
    let vault = ProfileCredentialVaultStub(values: [
      .init("webdav.server.7"):
        AndroidWebDAVServerCredential(username: "old", password: "old-secret")
    ])
    let useCase = AndroidWebDAVServerProfileRestoreUseCase(
      repository: repository,
      vault: vault
    )
    let plan = AndroidServerProfileImportPlan(
      entries: [
        .webDAV(
          AndroidWebDAVServerProfile(
            id: 7,
            name: "新书库",
            url: "https://new.example/books",
            username: "new",
            password: "new-secret",
            sortNumber: 2
          )
        ),
        .webDAV(
          AndroidWebDAVServerProfile(
            id: 8,
            name: "新增",
            url: "https://new.example/other",
            username: "added",
            password: "added-secret",
            sortNumber: 3
          )
        ),
      ],
      selectedID: 8
    )

    await #expect(throws: ProfilePersistenceFailure.rejected) {
      try await useCase.restore(plan)
    }
    #expect(try await repository.webDAVServerProfiles() == [oldProfile])
    #expect(try await repository.selectedWebDAVServerProfileID() == 7)
    #expect(
      await vault.credential(for: .init("webdav.server.7"))
        == AndroidWebDAVServerCredential(
          username: "old",
          password: "old-secret"
        )
    )
    #expect(await vault.credential(for: .init("webdav.server.8")) == nil)
  }

  @Test func exportWritesEncryptedProfilesAndSelectedServerForAndroid() async throws {
    let useCase = AndroidLibraryBackupUseCase(
      repository: EmptyProfileBackupRepository()
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
      webDAVConfiguration: nil,
      webDAVServerProfiles: [
        AndroidWebDAVServerProfileExportInput(
          id: 7,
          name: "主书库",
          serverAddress: "https://dav.example/books",
          username: "reader",
          password: "secret",
          sortNumber: 10
        )
      ],
      selectedWebDAVServerID: 7,
      backupPassword: "backup-pass"
    )

    let restored = try AndroidBackupArchive.readServerProfiles(
      from: archiveURL,
      backupPassword: "backup-pass"
    )
    let profile = try #require(restored.first)
    let restoredPreferences = try AndroidBackupArchive.readSharedPreferences(
      from: archiveURL
    )
    let preferences = try #require(restoredPreferences)
    #expect(summary.webDAVServerProfileCount == 1)
    #expect(profile.id == 7)
    #expect(profile.name == "主书库")
    #expect(profile.config?.contains(#""password":"secret""#) == true)
    #expect(
      preferences.values[AndroidWebDAVBackupConfiguration.remoteServerIDKey]
        == .long(7)
    )
  }

  @Test func coreRestorePreflightsEncryptedProfilesAndCarriesSelection() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let archiveURL = directory.appendingPathComponent("backup.zip")
    let profile = AndroidServerProfileDTO(
      id: 7,
      name: "主书库",
      config: #"{"url":"https://dav.example/books","username":"reader","password":"secret"}"#,
      sortNumber: 10
    )
    try AndroidBackupArchive.write(
      AndroidBackupContents(
        sharedPreferences: AndroidSharedPreferencesDocument(values: [
          AndroidWebDAVBackupConfiguration.remoteServerIDKey: .long(7)
        ]),
        serverProfilesPayload: try AndroidServerProfileCodec
          .encodeArchivePayload([profile], backupPassword: "backup-pass")
      ),
      to: archiveURL
    )
    let repository = CoreProfileRestoreRepositoryStub()

    let summary = try await AndroidCoreBackupRestoreUseCase(
      repository: repository
    ).restore(from: archiveURL, backupPassword: "backup-pass")
    let plan = try #require(await repository.profilePlan())

    #expect(summary.webDAVServerProfileCount == 1)
    #expect(summary.webDAVConfigurationCount == 0)
    #expect(plan.selectedID == 7)
    #expect(plan.webDAVProfiles.first?.id == 7)
  }
}

private enum ProfilePersistenceFailure: Error {
  case rejected
}

private actor ProfileRepositoryStub: WebDAVServerProfileRepository {
  private var profiles: [WebDAVServerProfile]
  private var selectedID: Int64?
  private var failsNextReplace: Bool

  init(
    profiles: [WebDAVServerProfile] = [],
    selectedID: Int64? = nil,
    failsNextReplace: Bool = false
  ) {
    self.profiles = profiles
    self.selectedID = selectedID
    self.failsNextReplace = failsNextReplace
  }

  func webDAVServerProfiles() async throws -> [WebDAVServerProfile] {
    profiles
  }

  func selectedWebDAVServerProfileID() async throws -> Int64? {
    selectedID
  }

  func replaceWebDAVServerProfiles(
    _ profiles: [WebDAVServerProfile],
    selectedID: Int64?
  ) async throws {
    if failsNextReplace {
      failsNextReplace = false
      throw ProfilePersistenceFailure.rejected
    }
    self.profiles = profiles
    self.selectedID = selectedID
  }
}

private actor ProfileCredentialVaultStub: AndroidWebDAVServerCredentialVault {
  private var values: [WebDAVCredentialReference: AndroidWebDAVServerCredential]

  init(
    values: [WebDAVCredentialReference: AndroidWebDAVServerCredential] = [:]
  ) {
    self.values = values
  }

  func credential(
    for reference: WebDAVCredentialReference
  ) async -> AndroidWebDAVServerCredential? {
    values[reference]
  }

  func save(
    _ credential: AndroidWebDAVServerCredential,
    for reference: WebDAVCredentialReference
  ) async throws {
    values[reference] = credential
  }

  func remove(reference: WebDAVCredentialReference) async {
    values[reference] = nil
  }
}

private struct EmptyProfileBackupRepository: AndroidLibraryBackupRepository {
  func androidLibraryBackupPlan() async throws -> AndroidLibraryRestorePlan {
    AndroidLibraryRestorePlan(books: [], groups: [], bookmarks: [])
  }
}

private actor CoreProfileRestoreRepositoryStub:
  AndroidCoreBackupRestoreRepository
{
  private var storedPlan: AndroidServerProfileImportPlan?

  func restoreAndroidLibrary(
    _ plan: AndroidLibraryRestorePlan
  ) async throws -> AndroidLibraryRestoreSummary {
    AndroidLibraryRestoreSummary(
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

  func restoreAndroidWebDAVServerProfiles(
    _ plan: AndroidServerProfileImportPlan
  ) async throws {
    storedPlan = plan
  }

  func profilePlan() -> AndroidServerProfileImportPlan? { storedPlan }
}
