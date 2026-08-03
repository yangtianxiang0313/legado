import AndroidBackupInterop
import Testing

@Suite("AndroidBackupAESInteropTests")
struct AndroidBackupAESInteropTests {
  @Test func matchesFrozenHutoolCiphertext() throws {
    #expect(
      try AndroidBackupAES.encryptBase64(
        "webdav-secret",
        backupPassword: "backup-pass"
      ) == "0LSuhOm3EXMTTUpsnaZ4lg=="
    )
    #expect(
      try AndroidBackupAES.decryptBase64(
        "0LSuhOm3EXMTTUpsnaZ4lg==",
        backupPassword: "backup-pass"
      ) == "webdav-secret"
    )
  }

  @Test func derivesAndroidAsciiMD5PrefixKey() {
    #expect(
      String(
        data: AndroidBackupAES.keyData(backupPassword: "backup-pass"),
        encoding: .utf8
      ) == "76190882d842ad1d"
    )
  }

  @Test func roundTripsUnicodePasswordValue() throws {
    let encrypted = try AndroidBackupAES.encryptBase64(
      "密码🔐",
      backupPassword: "备份口令"
    )
    #expect(
      try AndroidBackupAES.decryptBase64(
        encrypted,
        backupPassword: "备份口令"
      ) == "密码🔐"
    )
  }

  @Test func wrongBackupPasswordFailsClosed() throws {
    #expect(throws: AndroidBackupAESError.self) {
      try AndroidBackupAES.decryptBase64(
        "0LSuhOm3EXMTTUpsnaZ4lg==",
        backupPassword: "wrong"
      )
    }
  }

  @Test func malformedPayloadFailsClosed() {
    #expect(throws: AndroidBackupAESError.invalidBase64) {
      try AndroidBackupAES.decryptBase64(
        "not-base64!",
        backupPassword: "backup-pass"
      )
    }
  }
}
