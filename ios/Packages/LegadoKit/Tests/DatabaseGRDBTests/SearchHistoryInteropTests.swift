import AndroidBackupInterop
import AppUseCases
import BackupInteropUseCases
import DatabaseGRDB
import Foundation
import LegadoCore
import Testing

@Suite("SearchHistoryInteropTests")
struct SearchHistoryInteropTests {
  @MainActor
  @Test func recordsUsageAndRoundTripsAndroidArchiveLosslessly() async throws {
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
    let library = ShelfLibrary(repository: repository)

    await library.recordSearchKeyword(" 星河 ", atMilliseconds: 1_000)
    await library.recordSearchKeyword("星河", atMilliseconds: 2_000)

    let stored = try await repository.androidSearchHistory()
    #expect(
      stored == [
        SearchHistoryEntry(word: "星河", usage: 2, lastUseTime: 2_000)
      ]
    )

    let archiveURL = directory.appendingPathComponent("backup.zip")
    let document = AndroidSearchHistoryDTO(
      word: stored[0].word,
      usage: stored[0].usage,
      lastUseTime: stored[0].lastUseTime,
      unknownFields: ["future": .bool(true)]
    )
    try AndroidBackupArchive.write(
      AndroidBackupContents(searchHistory: [document]),
      to: archiveURL
    )
    let restored = try AndroidBackupArchive.readSearchHistory(from: archiveURL)

    #expect(restored == [document])
    #expect(restored[0].rawFields["future"] == .bool(true))
    #expect(
      AndroidSearchHistoryInteropAdapter.restoreValues(restored)
        == stored
    )
  }
}
