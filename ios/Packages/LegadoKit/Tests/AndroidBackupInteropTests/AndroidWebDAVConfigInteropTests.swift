import AndroidBackupInterop
import Foundation
import Testing

@Suite("AndroidWebDAVConfigInteropTests")
struct AndroidWebDAVConfigInteropTests {
  @Test func decodesAndroidSharedPreferencesAndPreservesTypedValues() throws {
    let data = Data(
      """
      <?xml version='1.0' encoding='utf-8' standalone='yes' ?>
      <map>
        <string name="web_dav_url">https://dav.example/a&amp;b</string>
        <string name="web_dav_account">reader@example.com</string>
        <string name="web_dav_password">opaque-base64</string>
        <string name="webDavDir">legado/shared</string>
        <string name="webDavDeviceName">Pixel</string>
        <boolean name="syncBookProgress" value="false" />
        <boolean name="onlyLatestBackup" value="false" />
        <boolean name="showDiscovery" value="false" />
        <boolean name="showRss" value="true" />
        <int name="bookshelfSort" value="4" />
        <string name="defaultHomePage">my</string>
        <boolean name="enableReadRecord" value="false" />
        <boolean name="ttsFollowSys" value="false" />
        <int name="ttsSpeechRate" value="15" />
        <int name="threadCount" value="8" />
        <long name="lastBackup" value="1700000000000" />
        <float name="textSize" value="18.5" />
      </map>
      """.utf8
    )

    let document = try AndroidSharedPreferencesCodec.decode(data)
    let webDAV = AndroidWebDAVBackupConfiguration(document: document)
    let application = AndroidApplicationBackupPreferences(
      document: document
    )

    #expect(webDAV.serverAddress == "https://dav.example/a&b")
    #expect(webDAV.username == "reader@example.com")
    #expect(webDAV.unresolvedPasswordPayload == "opaque-base64")
    #expect(webDAV.directoryName == "legado/shared")
    #expect(webDAV.syncBookProgress == false)
    #expect(webDAV.webDAVDeviceName == "Pixel")
    #expect(webDAV.onlyLatestBackup == false)
    #expect(application.showsDiscovery == false)
    #expect(application.showsRSS == true)
    #expect(application.bookshelfSort == 4)
    #expect(application.defaultHomePage == "my")
    #expect(application.enablesReadRecord == false)
    #expect(application.ttsFollowsSystemRate == false)
    #expect(application.ttsSpeechRate == 15)
    #expect(document.values["onlyLatestBackup"] == .boolean(false))
    #expect(document.values["threadCount"] == .int(8))
    #expect(document.values["lastBackup"] == .long(1_700_000_000_000))
    #expect(document.values["textSize"] == .float(18.5))

    let roundTrip = try AndroidSharedPreferencesCodec.decode(
      AndroidSharedPreferencesCodec.encode(document)
    )
    #expect(roundTrip == document)
  }

  @Test func writesAndReadsConfigXMLArchiveMember() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let archiveURL = directory.appendingPathComponent("backup.zip")
    let document = AndroidSharedPreferencesDocument(values: [
      AndroidWebDAVBackupConfiguration.serverAddressKey:
        .string("https://dav.example/root"),
      AndroidWebDAVBackupConfiguration.usernameKey: .string("reader"),
      AndroidWebDAVBackupConfiguration.passwordKey: .string("encrypted"),
      AndroidWebDAVBackupConfiguration.directoryNameKey: .string("legado"),
      AndroidWebDAVBackupConfiguration.syncBookProgressKey: .boolean(false),
      AndroidWebDAVBackupConfiguration.webDAVDeviceNameKey: .string("Pixel"),
      AndroidWebDAVBackupConfiguration.onlyLatestBackupKey: .boolean(false),
    ])

    try AndroidBackupArchive.write(
      AndroidBackupContents(sharedPreferences: document),
      to: archiveURL
    )

    #expect(
      try AndroidBackupArchive.readSharedPreferences(from: archiveURL)
        == document
    )
    #expect(
      try AndroidBackupArchive.readWebDAVBackupConfiguration(
        from: archiveURL
      )?.webDAVDeviceName == "Pixel"
    )
  }

  @Test func rejectsDuplicatePreferenceKeys() {
    let data = Data(
      "<map><string name=\"same\">a</string><string name=\"same\">b</string></map>".utf8
    )
    #expect(throws: AndroidSharedPreferencesCodecError.duplicateKey("same")) {
      try AndroidSharedPreferencesCodec.decode(data)
    }
  }
}
