import AppUseCases
import Foundation
import IntegrationKit
import Testing

@MainActor
@Suite("WebDAVRemoteBookBrowserStoreTests")
struct WebDAVRemoteBookBrowserStoreTests {
  @Test func loadsSelectedServerNavigatesAndDownloads() async throws {
    let profile = WebDAVServerProfile(
      id: 7,
      name: "主书库",
      serverAddress: "https://dav.example/books",
      sortNumber: 0,
      credentialReference: .init("webdav.server.7")
    )
    let repository = BrowserProfileRepositoryStub(
      profiles: [profile],
      selectedID: 7
    )
    let transfer = BrowserTransferStub()
    let store = WebDAVRemoteBookBrowserStore(
      repository: repository,
      transfer: transfer
    )

    await store.load()
    let directory = try #require(store.resources.first)
    #expect(store.selectedProfileID == 7)
    #expect(directory.name == "古典")

    await store.open(directory)
    let file = try #require(store.resources.first)
    #expect(store.canNavigateBack)
    #expect(file.name == "论语.txt")
    let download = await store.download(file)
    #expect(download?.name == "论语.txt")
    #expect(String(data: download?.data ?? Data(), encoding: .utf8) == "正文")

    await store.navigateBack()
    #expect(!store.canNavigateBack)
    #expect(store.resources.first?.name == "古典")
  }
}

private actor BrowserProfileRepositoryStub: WebDAVServerProfileRepository {
  private var profiles: [WebDAVServerProfile]
  private var selectedID: Int64?

  init(profiles: [WebDAVServerProfile], selectedID: Int64?) {
    self.profiles = profiles
    self.selectedID = selectedID
  }

  func webDAVServerProfiles() async throws -> [WebDAVServerProfile] {
    profiles
  }

  func selectedWebDAVServerProfileID() async throws -> Int64? { selectedID }

  func replaceWebDAVServerProfiles(
    _ profiles: [WebDAVServerProfile],
    selectedID: Int64?
  ) async throws {
    self.profiles = profiles
    self.selectedID = selectedID
  }

  func selectWebDAVServerProfile(id: Int64?) async throws {
    selectedID = id
  }
}

private struct BrowserTransferStub: WebDAVRemoteBookTransferring {
  func listRemoteBooks(
    configuration: WebDAVConnectionConfiguration,
    directoryURL: URL?
  ) async -> WebDAVRemoteBookListResult {
    guard let rootURL = configuration.rootURL else {
      return .failed(.invalidConfiguration)
    }
    if directoryURL == nil {
      return .loaded([
        WebDAVRemoteBookResource(
          name: "古典",
          url: rootURL.appendingPathComponent("古典", isDirectory: true),
          size: 0,
          lastModifiedMilliseconds: 0,
          isDirectory: true
        )
      ])
    }
    return .loaded([
      WebDAVRemoteBookResource(
        name: "论语.txt",
        url: directoryURL!.appendingPathComponent("论语.txt"),
        size: 6,
        lastModifiedMilliseconds: 0,
        isDirectory: false
      )
    ])
  }

  func downloadRemoteBook(
    configuration: WebDAVConnectionConfiguration,
    resource: WebDAVRemoteBookResource
  ) async -> WebDAVRemoteBookDownloadResult {
    .downloaded(name: resource.name, data: Data("正文".utf8))
  }
}
