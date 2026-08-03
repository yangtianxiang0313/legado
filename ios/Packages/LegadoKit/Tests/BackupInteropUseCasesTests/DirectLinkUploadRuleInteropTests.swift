import AndroidBackupInterop
import AppUseCases
import BackupInteropUseCases
import Foundation
import LegadoCore
import Testing

@Suite("DirectLinkUploadRuleInteropTests")
struct DirectLinkUploadRuleInteropTests {
  @Test func decodesAndroidObjectAndPreservesUnknownFields() throws {
    let data = Data(
      #"{"uploadUrl":"https://upload.example/{{fileName}}","downloadUrlRule":"$.data.url","summary":"对象存储","compress":true,"futureHeader":"x-token"}"#.utf8
    )

    let document = try AndroidDirectLinkUploadRuleCodec.decode(data)
    let value = try #require(
      AndroidDirectLinkUploadRuleInteropAdapter.restoreValue(document)
    )

    #expect(value.uploadURL == "https://upload.example/{{fileName}}")
    #expect(value.downloadURLRule == "$.data.url")
    #expect(value.summary == "对象存储")
    #expect(value.compress)
    #expect(value.unknownFields == ["futureHeader": .string("x-token")])

    let encoded = try AndroidDirectLinkUploadRuleCodec.encode(
      #require(
        AndroidDirectLinkUploadRuleInteropAdapter.backupDocument(value)
      )
    )
    let encodedValue = try JSONValueCodec.decode(encoded)
    let originalValue = try JSONValueCodec.decode(data)
    #expect(encodedValue == originalValue)
  }

  @Test func archiveWritesObjectMemberAndMissingMemberIsNil() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let populated = directory.appendingPathComponent("populated.zip")
    let document = try #require(
      AndroidDirectLinkUploadRuleInteropAdapter.backupDocument(
        DirectLinkUploadRule(
          uploadURL: "https://upload.example",
          downloadURLRule: "$.url",
          summary: "test",
          compress: false
        )
      )
    )
    try AndroidBackupArchive.write(
      AndroidBackupContents(directLinkUploadRule: document),
      to: populated
    )
    #expect(
      try AndroidBackupArchive.readDirectLinkUploadRule(from: populated)
        == document
    )

    let empty = directory.appendingPathComponent("empty.zip")
    try AndroidBackupArchive.write(
      AndroidBackupContents(
        sharedPreferences: AndroidSharedPreferencesDocument()
      ),
      to: empty
    )
    #expect(
      try AndroidBackupArchive.readDirectLinkUploadRule(from: empty) == nil
    )
  }

  @Test func nonObjectPayloadIsRejected() {
    #expect(throws: AndroidReplaceRuleFormatError.expectedObject) {
      try AndroidDirectLinkUploadRuleCodec.decode(Data("[]".utf8))
    }
  }
}
