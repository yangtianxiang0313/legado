import AndroidBackupInterop
import AppUseCases
import BackupInteropUseCases
import DatabaseGRDB
import Foundation
import Testing

@Suite("DictionaryInteropTests")
struct DictionaryInteropTests {
  @Test func archiveAndDatabaseRoundTripAndroidRules() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let json = Data(#"[{"name":"词典","urlRule":"https://dict.test?q={{key}}","showRule":"$.value","enabled":true,"sortNumber":2,"future":1}]"#.utf8)
    let documents = try AndroidDictionaryRuleCodec.decodeMany(json)
    let archive = directory.appendingPathComponent("android.zip")
    try AndroidBackupArchive.write(
      AndroidBackupContents(dictionaryRules: documents),
      to: archive
    )
    let values = AndroidDictionaryRuleInteropAdapter.restoreValues(
      try AndroidBackupArchive.readDictionaryRules(from: archive)
    )
    let repository = try GRDBBookShelfRepository(
      path: directory.appendingPathComponent("library.sqlite").path
    )
    try await repository.restoreAndroidDictionaryRules(values)

    #expect(try await repository.dictionaryRules() == values)
    #expect(documents[0].rawFields["future"] != nil)
  }
}
