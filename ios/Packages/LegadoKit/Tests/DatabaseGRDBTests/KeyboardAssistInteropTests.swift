import AndroidBackupInterop
import AppUseCases
import BackupInteropUseCases
import DatabaseGRDB
import Foundation
import LegadoCore
import Testing

@Suite("KeyboardAssistInteropTests")
struct KeyboardAssistInteropTests {
  @Test func androidJSONArchiveDatabaseAndExportRoundTrip() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let json = Data(
      #"[{"type":0,"key":"{{}}","value":"{{}}","serialNo":2,"future":"kept"},{"type":1,"key":"x","value":"y","serialNo":1}]"#.utf8
    )
    let documents = try AndroidKeyboardAssistCodec.decodeMany(json)
    let inputArchive = directory.appendingPathComponent("android.zip")
    try AndroidBackupArchive.write(
      AndroidBackupContents(keyboardAssists: documents),
      to: inputArchive
    )
    let values = AndroidKeyboardAssistInteropAdapter.restoreValues(
      try AndroidBackupArchive.readKeyboardAssists(from: inputArchive)
    )
    let repository = try GRDBBookShelfRepository(
      path: directory.appendingPathComponent("library.sqlite").path
    )
    try await repository.restoreAndroidKeyboardAssists(values)

    let stored = try await repository.keyboardAssists()
    #expect(stored == values)
    let exported = AndroidKeyboardAssistInteropAdapter.backupDocuments(stored)
    #expect(exported[0].rawFields["future"] == .string("kept"))
  }

  @Test @MainActor func storeUsesAndroidTypeAndSerialOrdering() async throws {
    let store = KeyboardAssistStore(
      repository: KeyboardAssistRepositoryStub(values: [
        KeyboardAssist(type: 0, key: "later", value: "L", serialNumber: 9),
        KeyboardAssist(type: 1, key: "hidden", value: "H", serialNumber: 0),
        KeyboardAssist(type: 0, key: "first", value: "F", serialNumber: 1),
      ])
    )
    await store.reload()
    #expect(store.values.map(\.key) == ["first", "later"])
  }
}

private actor KeyboardAssistRepositoryStub: KeyboardAssistRepository {
  let values: [KeyboardAssist]

  init(values: [KeyboardAssist]) {
    self.values = values
  }

  func keyboardAssists() async throws -> [KeyboardAssist] { values }
  func restoreAndroidKeyboardAssists(_ values: [KeyboardAssist]) async throws {}
}
