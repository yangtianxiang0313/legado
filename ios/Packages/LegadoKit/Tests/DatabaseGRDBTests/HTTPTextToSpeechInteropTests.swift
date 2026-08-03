import AndroidBackupInterop
import AppUseCases
import BackupInteropUseCases
import DatabaseGRDB
import Foundation
import LegadoCore
import Testing

@Suite("HTTPTextToSpeechInteropTests")
struct HTTPTextToSpeechInteropTests {
  @Test func roundTripsAndroidArchiveRestorePersistenceAndExport() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let engine = HTTPTextToSpeechEngine(
      id: 1_728_000_000_001,
      name: "Android 在线朗读",
      url: "https://tts.example.com/audio?text={{speakText}}&speed={{speakSpeed}}",
      contentType: "audio/.*",
      concurrentRate: "2/1000",
      loginURL: "https://tts.example.com/login",
      loginUI: #"[{"name":"token","type":"text"}]"#,
      header: #"{"User-Agent":"Legado","Authorization":"Bearer token"}"#,
      jsLib: "function sign(value) { return value; }",
      enabledCookieJar: true,
      loginCheckJS: "result",
      lastUpdateTime: 1_728_000_000_999
    )
    let document = AndroidHTTPTextToSpeechInteropAdapter
      .backupDocuments([engine])[0]
    #expect(
      AndroidHTTPTextToSpeechInteropAdapter.restoreValues([document]) == [engine]
    )

    let sourceArchive = directory.appendingPathComponent("android.zip")
    try AndroidBackupArchive.write(
      AndroidBackupContents(httpTextToSpeechEngines: [document]),
      to: sourceArchive
    )
    #expect(
      try AndroidBackupArchive.readHTTPTextToSpeechEngines(
        from: sourceArchive
      ) == [document]
    )

    let repository = try GRDBBookShelfRepository(
      path: directory.appendingPathComponent("library.sqlite").path
    )
    let restored = AndroidHTTPTextToSpeechInteropAdapter.restoreValues(
      try AndroidBackupArchive.readHTTPTextToSpeechEngines(from: sourceArchive)
    )
    try await repository.restoreAndroidHTTPTextToSpeechEngines(restored)
    #expect(try await repository.httpTextToSpeechEngines() == [engine])

    let exportedArchive = directory.appendingPathComponent("ios.zip")
    let exported = AndroidHTTPTextToSpeechInteropAdapter.backupDocuments(
      try await repository.androidHTTPTextToSpeechEngines()
    )
    try AndroidBackupArchive.write(
      AndroidBackupContents(httpTextToSpeechEngines: exported),
      to: exportedArchive
    )
    #expect(
      AndroidHTTPTextToSpeechInteropAdapter.restoreValues(
        try AndroidBackupArchive.readHTTPTextToSpeechEngines(
          from: exportedArchive
        )
      ) == [engine]
    )
  }

  @Test func codecPreservesUnknownAndroidFields() throws {
    let json = Data(#"[{"id":7,"name":"TTS","url":"https://tts.test","futureOption":{"mode":"new"}}]"#.utf8)
    let decoded = try AndroidHTTPTextToSpeechCodec.decodeMany(json)
    let encoded = try AndroidHTTPTextToSpeechCodec.encodeMany(decoded)
    #expect(try AndroidHTTPTextToSpeechCodec.decodeMany(encoded) == decoded)
    #expect(decoded[0].rawFields["futureOption"] != nil)
  }
}
