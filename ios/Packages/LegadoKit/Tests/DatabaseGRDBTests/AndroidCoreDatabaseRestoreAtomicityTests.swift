import AppUseCases
import BackupInteropUseCases
import DatabaseGRDB
import Foundation
import Testing

@Suite("AndroidCoreDatabaseRestoreAtomicityTests")
struct AndroidCoreDatabaseRestoreAtomicityTests {
  @Test func laterDomainFailureRollsBackEarlierDomainWrites() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseURL = directory.appendingPathComponent("library.sqlite")
    let repository = try GRDBBookShelfRepository(path: databaseURL.path)
    try installDictionaryFailureTrigger(databaseURL: databaseURL)
    let payload = AndroidCoreDatabaseRestorePayload(
      library: AndroidLibraryRestorePlan(
        books: [],
        groups: [],
        bookmarks: []
      ),
      replacementRules: [
        ReaderReplacementRule(
          id: "android-rule",
          name: "先写入的替换规则",
          pattern: "ad",
          replacement: ""
        )
      ],
      dictionaryRules: [
        DictionaryRule(
          name: "触发失败的词典",
          urlRule: "https://dict.invalid/{{key}}"
        )
      ]
    )

    await #expect(throws: (any Error).self) {
      try await repository.restoreAndroidDatabaseDomains(payload)
    }

    #expect(try await repository.replacementRules().isEmpty)
    #expect(try await repository.dictionaryRules().isEmpty)
  }

  @Test func allDatabaseDomainsCommitTogetherOnSuccess() async throws {
    let repository = try GRDBBookShelfRepository(path: ":memory:")
    let replacementRule = ReaderReplacementRule(
      id: "android-rule",
      name: "替换规则",
      pattern: "ad",
      replacement: ""
    )
    let dictionaryRule = DictionaryRule(
      name: "词典",
      urlRule: "https://dict.invalid/{{key}}"
    )
    let summary = try await repository.restoreAndroidDatabaseDomains(
      AndroidCoreDatabaseRestorePayload(
        library: AndroidLibraryRestorePlan(
          books: [],
          groups: [],
          bookmarks: []
        ),
        replacementRules: [replacementRule],
        dictionaryRules: [dictionaryRule]
      )
    )

    #expect(summary.bookCount == 0)
    #expect(try await repository.replacementRules() == [replacementRule])
    #expect(try await repository.dictionaryRules() == [dictionaryRule])
  }

  private func installDictionaryFailureTrigger(databaseURL: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [
      databaseURL.path,
      """
      CREATE TRIGGER reject_dictionary_restore
      BEFORE INSERT ON dictionaryRules
      BEGIN
        SELECT RAISE(ABORT, 'injected dictionary restore failure');
      END;
      """,
    ]
    let errorPipe = Pipe()
    process.standardError = errorPipe
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
      throw SQLiteFixtureError.commandFailed(
        String(decoding: data, as: UTF8.self)
      )
    }
  }
}

private enum SQLiteFixtureError: Error {
  case commandFailed(String)
}
