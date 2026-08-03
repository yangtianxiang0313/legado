import AppUseCases
import IntegrationKit
import Testing

@Suite("WebDAVDefaultServerBridgeTests")
struct WebDAVDefaultServerBridgeTests {
  @Test func projectsPrimarySettingsToAndroidDefaultBooksServer() throws {
    let settings = WebDAVConnectionSettings(
      serverAddress: "https://dav.example/root",
      directoryName: "legado",
      credentialReference: .init("webdav.primary")
    )

    let profile = try #require(
      WebDAVDefaultServerBridge.profile(settings: settings)
    )

    #expect(profile.id == -1)
    #expect(profile.serverAddress == "https://dav.example/root/legado/books/")
    #expect(profile.credentialReference.rawValue == "webdav.primary")
    #expect(profile.isAndroidDefault)
  }

  @Test func excludesSyntheticDefaultFromAndroidServersExport() {
    let profiles = [
      WebDAVServerProfile(
        id: -1,
        name: "默认",
        serverAddress: "https://dav.example/root/books/",
        sortNumber: Int.min,
        credentialReference: .init("primary")
      ),
      WebDAVServerProfile(
        id: 7,
        name: "独立书库",
        serverAddress: "https://dav.example/library/",
        sortNumber: 1,
        credentialReference: .init("server.7")
      ),
    ]

    #expect(
      WebDAVDefaultServerBridge.androidExportProfiles(profiles).map(\.id)
        == [7]
    )
    #expect(WebDAVDefaultServerBridge.androidExportSelectedID(-1) == nil)
    #expect(WebDAVDefaultServerBridge.androidExportSelectedID(7) == 7)
  }
}
