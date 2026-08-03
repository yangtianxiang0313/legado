import AppUseCases
import DatabaseGRDB
import IntegrationKit
import Testing

@Suite("WebDAVDefaultServerBridgeTests")
struct WebDAVDefaultServerBridgePersistenceTests {
  @Test func replacingAndroidProfilesPreservesSyntheticDefault() async throws {
    let repository = try GRDBBookShelfRepository(path: ":memory:")
    let defaultProfile = WebDAVServerProfile(
      id: -1,
      name: "默认 WebDAV",
      serverAddress: "https://dav.example/root/books/",
      sortNumber: Int.min,
      credentialReference: .init("webdav.primary")
    )
    let imported = WebDAVServerProfile(
      id: 7,
      name: "Android 书库",
      serverAddress: "https://dav.example/library/",
      sortNumber: 1,
      credentialReference: .init("webdav.server.7")
    )

    try await repository.upsertWebDAVServerProfile(defaultProfile)
    try await repository.replaceWebDAVServerProfiles([imported], selectedID: 7)

    #expect(
      try await repository.webDAVServerProfiles().map(\.id) == [-1, 7]
    )
    #expect(try await repository.selectedWebDAVServerProfileID() == 7)
  }
}
