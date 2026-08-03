import AppUseCases
import DatabaseGRDB
import Foundation
import Testing

@Suite("DirectLinkUploadRulePersistenceTests")
struct DirectLinkUploadRuleDatabasePersistenceTests {
  @Test func persistsSingletonAcrossRepositoryReopen() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("library.sqlite").path
    let rule = DirectLinkUploadRule(
      uploadURL: "https://upload.example",
      downloadURLRule: "$.url",
      summary: "test",
      compress: false,
      unknownFields: ["future": .bool(true)]
    )

    let repository = try GRDBBookShelfRepository(path: path)
    #expect(try await repository.directLinkUploadRule() == nil)
    try await repository.restoreAndroidDirectLinkUploadRule(rule)
    #expect(try await repository.directLinkUploadRule() == rule)

    let reopened = try GRDBBookShelfRepository(path: path)
    #expect(try await reopened.directLinkUploadRule() == rule)
  }
}
