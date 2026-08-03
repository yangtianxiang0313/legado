import AppUseCases
import DatabaseGRDB
import Foundation
import Testing

@Suite("RSSContentStarTests")
struct RSSContentStarPersistenceTests {
  @Test func deletesOnlyTheAndroidCompositeKey() async throws {
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
    let first = RSSStar(origin: "source-a", title: "A", link: "same-link")
    let second = RSSStar(origin: "source-b", title: "B", link: "same-link")
    try await repository.upsertRSSStar(first)
    try await repository.upsertRSSStar(second)

    try await repository.deleteRSSStar(origin: first.origin, link: first.link)

    #expect(try await repository.rssStars() == [second])
  }
}
