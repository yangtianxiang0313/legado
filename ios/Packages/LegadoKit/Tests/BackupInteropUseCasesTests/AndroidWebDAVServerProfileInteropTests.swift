import AndroidBackupInterop
import BackupInteropUseCases
import Foundation
import LegadoCore
import Testing

@Suite("AndroidWebDAVServerProfileInteropTests")
struct AndroidWebDAVServerProfileInteropTests {
  private let profile = AndroidServerProfileDTO(
    id: 1700000000123,
    name: "家庭书库",
    config: #"{"url":"https://dav.example/books","username":"reader","password":"secret"}"#,
    sortNumber: 7,
    unknownFields: ["future": .string("kept")]
  )

  @Test func plaintextRoundTripPreservesAndroidFieldsAndUnknownData() throws {
    let data = try AndroidServerProfileCodec.encodePlaintext([profile])
    let restored = try #require(
      AndroidServerProfileCodec.decodePlaintext(data).first
    )

    #expect(restored == profile)
    #expect(restored.id == 1700000000123)
    #expect(restored.type == "WEBDAV")
    #expect(restored.sortNumber == 7)
    #expect(restored.unknownFields["future"] == .string("kept"))
  }

  @Test func encryptedPayloadUsesAndroidBackupAESAndRoundTrips() throws {
    let payload = try AndroidServerProfileCodec.encodeArchivePayload(
      [profile],
      backupPassword: "backup-pass"
    )
    #expect(String(data: payload, encoding: .utf8)?.hasPrefix("[") == false)

    let restored = try AndroidServerProfileCodec.decodeArchivePayload(
      payload,
      backupPassword: "backup-pass"
    )
    #expect(restored == [profile])
  }

  @Test func encryptedPayloadRequiresTheCorrectPassword() throws {
    let payload = try AndroidServerProfileCodec.encodeArchivePayload(
      [profile],
      backupPassword: "backup-pass"
    )
    #expect(throws: AndroidServerProfileCodecError.backupPasswordRequired) {
      try AndroidServerProfileCodec.decodeArchivePayload(
        payload,
        backupPassword: nil
      )
    }
    #expect(throws: AndroidServerProfileCodecError.invalidBackupPassword) {
      try AndroidServerProfileCodec.decodeArchivePayload(
        payload,
        backupPassword: "wrong"
      )
    }
  }

  @Test func archiveProducesStructuredImportPlan() throws {
    let unsupported = AndroidServerProfileDTO(
      id: 2,
      name: "未来协议",
      type: "S3",
      config: nil,
      sortNumber: 8
    )
    let invalid = AndroidServerProfileDTO(
      id: 3,
      name: "损坏配置",
      config: "{}",
      sortNumber: 9
    )
    let payload = try AndroidServerProfileCodec.encodeArchivePayload(
      [profile, unsupported, invalid],
      backupPassword: "backup-pass"
    )
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let archiveURL = directory.appendingPathComponent("backup.zip")
    try AndroidBackupArchive.write(
      AndroidBackupContents(serverProfilesPayload: payload),
      to: archiveURL
    )

    let plan = try AndroidServerProfileImportAdapter.plan(
      from: archiveURL,
      backupPassword: "backup-pass"
    )
    #expect(
      plan.webDAVProfiles == [
        AndroidWebDAVServerProfile(
          id: 1700000000123,
          name: "家庭书库",
          url: "https://dav.example/books",
          username: "reader",
          password: "secret",
          sortNumber: 7
        )
      ]
    )
    #expect(plan.entries[1] == .unsupported(id: 2, name: "未来协议", type: "S3"))
    #expect(plan.entries[2] == .invalidWebDAVConfiguration(id: 3, name: "损坏配置"))
  }
}
