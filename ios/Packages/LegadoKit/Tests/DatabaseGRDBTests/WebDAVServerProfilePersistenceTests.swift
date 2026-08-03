import AppUseCases
import DatabaseGRDB
import Foundation
import IntegrationKit
import Testing

@Suite("WebDAVServerProfilePersistenceTests")
struct WebDAVServerProfilePersistenceTests {
  @Test func replacesProfilesAndPreservesAndroidSelectionAndOrder() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try GRDBBookShelfRepository(
      path: directory.appendingPathComponent("library.sqlite").path
    )
    let later = WebDAVServerProfile(
      id: 8,
      name: "后备",
      serverAddress: "https://dav.example/backup",
      sortNumber: 20,
      credentialReference: .init("webdav.server.8")
    )
    let first = WebDAVServerProfile(
      id: 7,
      name: "主书库",
      serverAddress: "https://dav.example/books",
      sortNumber: 10,
      credentialReference: .init("webdav.server.7")
    )

    try await repository.replaceWebDAVServerProfiles(
      [later, first],
      selectedID: 7
    )

    #expect(try await repository.webDAVServerProfiles() == [first, later])
    #expect(try await repository.selectedWebDAVServerProfileID() == 7)
  }
}
