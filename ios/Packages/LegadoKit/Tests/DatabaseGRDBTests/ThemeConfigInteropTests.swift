import AndroidBackupInterop
import AppUseCases
import BackupInteropUseCases
import DatabaseGRDB
import Foundation
import LegadoCore
import Testing

@Suite("ThemeConfigInteropTests")
struct ThemeConfigInteropTests {
  @Test func archiveDatabaseAndUnknownFieldsRoundTrip() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let json = Data(
      ##"[{"themeName":"典雅蓝","isNightTheme":false,"primaryColor":"#03A9F4","accentColor":"#AD1457","backgroundColor":"#F5F5F5","bottomBackground":"#EEEEEE","future":"kept"}]"##.utf8
    )
    let documents = try AndroidThemeConfigCodec.decodeMany(json)
    let archive = directory.appendingPathComponent("android.zip")
    try AndroidBackupArchive.write(
      AndroidBackupContents(themeConfigs: documents),
      to: archive
    )
    let values = AndroidThemeConfigInteropAdapter.restoreValues(
      try AndroidBackupArchive.readThemeConfigs(from: archive)
    )
    let repository = try GRDBBookShelfRepository(
      path: directory.appendingPathComponent("library.sqlite").path
    )
    try await repository.restoreAndroidThemeProfiles(values)

    let stored = try await repository.appThemeProfiles()
    #expect(stored == values)
    let exported = AndroidThemeConfigInteropAdapter.backupDocuments(stored)
    #expect(exported[0].rawFields["future"] == .string("kept"))
  }

  @Test @MainActor func importedProfilesDoNotImplySelection() async {
    let selection = ThemeSelectionStub()
    let store = AppThemeProfileStore(
      repository: ThemeProfileRepositoryStub(values: [
        AppThemeProfile(
          name: "黑白",
          isNightTheme: true,
          primaryColor: "#303030",
          accentColor: "#E0E0E0",
          backgroundColor: "#424242",
          bottomBackgroundColor: "#424242"
        )
      ]),
      selection: selection
    )
    await store.reload()
    #expect(store.selectedProfile == nil)

    store.select("黑白")
    #expect(store.selectedProfile?.isNightTheme == true)
    #expect(selection.value == "黑白")
  }
}

private actor ThemeProfileRepositoryStub: AppThemeProfileRepository {
  let values: [AppThemeProfile]

  init(values: [AppThemeProfile]) {
    self.values = values
  }

  func appThemeProfiles() async throws -> [AppThemeProfile] { values }
  func restoreAndroidThemeProfiles(_ values: [AppThemeProfile]) async throws {}
}

@MainActor
private final class ThemeSelectionStub: AppThemeSelectionPersistence {
  var value: String?
  func selectedThemeName() -> String? { value }
  func saveSelectedThemeName(_ value: String?) { self.value = value }
}
