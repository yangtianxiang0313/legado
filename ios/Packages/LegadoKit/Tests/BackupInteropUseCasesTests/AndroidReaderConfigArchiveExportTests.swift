import AndroidBackupInterop
import BackupInteropUseCases
import Foundation
import LegadoCore
import ReaderCore
import Testing

@Suite("Android reader config archive export")
struct AndroidReaderConfigArchiveExportTests {
  @Test func projectsCurrentIOSReaderPreferencesToAndroidConfiguration() throws {
    let configuration = try AndroidReaderConfigArchiveExport.configuration(
      name: "iOS 当前阅读配置",
      preferences: ReaderPreferences(
        fontSize: 24,
        lineSpacing: 10,
        pageAnimation: 2,
        layout: ReaderLayoutPreferences(
          textWeight: 1,
          letterSpacing: 0.2,
          paragraphSpacing: 3,
          paragraphIndent: "　　",
          titleMode: 1,
          paddingTop: 8,
          paddingBottom: 9,
          paddingLeft: 10,
          paddingRight: 11
        )
      )
    )
    #expect(configuration.integer("textSize") == 24)
    #expect(configuration.integer("lineSpacingExtra") == 10)
    #expect(configuration.integer("pageAnim") == 2)
    guard case .string(let name) = configuration.rawFields["name"] else {
      Issue.record("missing name")
      return
    }
    #expect(name == "iOS 当前阅读配置")
  }

  @Test func roundTripsConfigurationAndEveryAndroidResourceSlot() throws {
    let configuration = try AndroidReaderConfigDTO(jsonValue: .object([
      "name": .string("纸张/夜间"),
      "textSize": .number(JSONNumber(21)),
      "textFont": .string("/ios/fonts/custom.ttf"),
      "bgType": .number(JSONNumber(2)),
      "bgStr": .string("/ios/background/day.png"),
      "bgTypeNight": .number(JSONNumber(2)),
      "bgStrNight": .string("/ios/background/night.png"),
      "bgTypeEInk": .number(JSONNumber(2)),
      "bgStrEInk": .string("/ios/background/eink.png"),
    ]))
    let resources: [String: Data] = [
      "/ios/fonts/custom.ttf": Data([1]),
      "/ios/background/day.png": Data([2]),
      "/ios/background/night.png": Data([3]),
      "/ios/background/eink.png": Data([4]),
    ]

    let exported = try AndroidReaderConfigArchiveExport.encode(
      configuration,
      resourceLoader: { resources[$0] }
    )
    #expect(exported.filename == "纸张_夜间.zip")

    let archiveURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString + ".zip")
    let materializedRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer {
      try? FileManager.default.removeItem(at: archiveURL)
      try? FileManager.default.removeItem(at: materializedRoot)
    }
    try exported.data.write(to: archiveURL)
    let decoded = try AndroidReaderConfigArchiveImport.decode(from: archiveURL)
    #expect(decoded.configuration.integer("textSize") == 21)
    #expect(decoded.resources == [
      "custom.ttf": Data([1]),
      "day.png": Data([2]),
      "night.png": Data([3]),
      "eink.png": Data([4]),
    ])

    let materialized = try AndroidReaderConfigAssetMaterializer.materialize(
      decoded,
      rootURL: materializedRoot
    )
    for key in ["textFont", "bgStr", "bgStrNight", "bgStrEInk"] {
      guard case .string(let path) = materialized.rawFields[key] else {
        Issue.record("missing materialized path for \(key)")
        continue
      }
      #expect(FileManager.default.fileExists(atPath: path))
    }
  }

  @Test func ignoresColorBackgroundsAndRejectsBasenameCollision() throws {
    let colorsOnly = try AndroidReaderConfigDTO(jsonValue: .object([
      "name": .string("颜色"),
      "bgType": .number(JSONNumber(0)),
      "bgStr": .string("#ffffff"),
    ]))
    let colorExport = try AndroidReaderConfigArchiveExport.encode(
      colorsOnly,
      resourceLoader: { _ in
        Issue.record("color background must not load a file")
        return Data()
      }
    )
    let colorURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString + ".zip")
    defer { try? FileManager.default.removeItem(at: colorURL) }
    try colorExport.data.write(to: colorURL)
    #expect(try AndroidReaderConfigArchiveImport.decode(from: colorURL)
      .resources.isEmpty)

    let collision = try AndroidReaderConfigDTO(jsonValue: .object([
      "textFont": .string("/font/shared.bin"),
      "bgType": .number(JSONNumber(2)),
      "bgStr": .string("/background/shared.bin"),
    ]))
    #expect(throws: AndroidReaderConfigArchiveExportError
      .conflictingResourceName("shared.bin")) {
      try AndroidReaderConfigArchiveExport.encode(
        collision,
        resourceLoader: { path in
          path.hasPrefix("/font") ? Data([1]) : Data([2])
        }
      )
    }
  }
}
