import AppUseCases
import IntegrationKit
import Testing

@Suite("WebDAV server profile management")
struct WebDAVServerProfileManagementTests {
  @Test("create and update preserve Android identity while rotating credentials")
  func createAndUpdate() async throws {
    let repository = ManagementRepositoryStub()
    let vault = ManagementCredentialVaultStub()
    let useCase = WebDAVServerProfileManagementUseCase(
      repository: repository,
      vault: vault,
      makeID: { 1_728_000_000_123 }
    )

    let created = try await useCase.save(
      name: " 家庭书库 ",
      serverAddress: "https://dav.example/books/",
      username: "reader",
      password: "first"
    )
    #expect(created.id == 1_728_000_000_123)
    #expect(created.name == "家庭书库")
    #expect(
      created.credentialReference.rawValue
        == "webdav.server.1728000000123"
    )

    let updated = try await useCase.save(
      id: created.id,
      name: "家庭书库 2",
      serverAddress: "https://dav.example/library/",
      username: "reader2",
      password: "second",
      sortNumber: 8
    )
    #expect(updated.id == created.id)
    #expect(await repository.profiles.count == 1)
    #expect(await repository.profiles.first?.sortNumber == 8)
    #expect(
      await vault.values[created.credentialReference]?.password == "second"
    )
  }

  @Test("deleting selected server removes secret and falls back to default")
  func deleteSelected() async throws {
    let custom = Self.profile(id: 42, name: "私有书库")
    let defaultServer = Self.profile(
      id: WebDAVServerProfile.androidDefaultID,
      name: "默认 WebDAV"
    )
    let repository = ManagementRepositoryStub(
      profiles: [defaultServer, custom],
      selectedID: custom.id
    )
    let vault = ManagementCredentialVaultStub(values: [
      custom.credentialReference: WebDAVServerCredential(
        username: "reader",
        password: "secret"
      )
    ])
    let useCase = WebDAVServerProfileManagementUseCase(
      repository: repository,
      vault: vault
    )

    let selected = try await useCase.delete(id: custom.id)

    #expect(selected == WebDAVServerProfile.androidDefaultID)
    #expect(await repository.selectedID == selected)
    #expect(await repository.profiles == [defaultServer])
    #expect(await vault.values.isEmpty)
  }

  @Test("default server and invalid payload cannot enter custom management")
  func rejectsInvalidMutation() async throws {
    let repository = ManagementRepositoryStub()
    let vault = ManagementCredentialVaultStub()
    let useCase = WebDAVServerProfileManagementUseCase(
      repository: repository,
      vault: vault
    )

    await #expect(throws: WebDAVServerProfileManagementError.invalidServerAddress) {
      try await useCase.save(
        name: "bad",
        serverAddress: "file:///tmp/books",
        username: "reader",
        password: "secret"
      )
    }
    await #expect(throws: WebDAVServerProfileManagementError.cannotModifyDefaultServer) {
      try await useCase.delete(id: WebDAVServerProfile.androidDefaultID)
    }
  }

  private static func profile(
    id: Int64,
    name: String
  ) -> WebDAVServerProfile {
    WebDAVServerProfile(
      id: id,
      name: name,
      serverAddress: "https://dav.example/books/",
      sortNumber: 0,
      credentialReference: WebDAVCredentialReference("webdav.server.\(id)")
    )
  }
}

private actor ManagementRepositoryStub: WebDAVServerProfileRepository {
  var profiles: [WebDAVServerProfile]
  var selectedID: Int64?

  init(
    profiles: [WebDAVServerProfile] = [],
    selectedID: Int64? = nil
  ) {
    self.profiles = profiles
    self.selectedID = selectedID
  }

  func webDAVServerProfiles() -> [WebDAVServerProfile] { profiles }
  func selectedWebDAVServerProfileID() -> Int64? { selectedID }

  func replaceWebDAVServerProfiles(
    _ profiles: [WebDAVServerProfile],
    selectedID: Int64?
  ) {
    self.profiles = profiles
    self.selectedID = selectedID
  }

  func upsertWebDAVServerProfile(_ profile: WebDAVServerProfile) {
    profiles.removeAll { $0.id == profile.id }
    profiles.append(profile)
  }

  func deleteWebDAVServerProfile(id: Int64) {
    profiles.removeAll { $0.id == id }
  }

  func selectWebDAVServerProfile(id: Int64?) { selectedID = id }
}

private actor ManagementCredentialVaultStub: WebDAVServerCredentialVault {
  var values: [WebDAVCredentialReference: WebDAVServerCredential]

  init(
    values: [WebDAVCredentialReference: WebDAVServerCredential] = [:]
  ) {
    self.values = values
  }

  func credential(
    for reference: WebDAVCredentialReference
  ) -> WebDAVServerCredential? {
    values[reference]
  }

  func save(
    _ credential: WebDAVServerCredential,
    for reference: WebDAVCredentialReference
  ) {
    values[reference] = credential
  }

  func remove(reference: WebDAVCredentialReference) {
    values.removeValue(forKey: reference)
  }
}
