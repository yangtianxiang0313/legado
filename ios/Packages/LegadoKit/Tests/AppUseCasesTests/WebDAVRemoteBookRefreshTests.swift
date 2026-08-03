import AppUseCases
import Foundation
import IntegrationKit
import Testing

@Suite("WebDAVRemoteBookRefreshTests")
struct WebDAVRemoteBookRefreshUseCaseTests {
  @Test func downloadsOnlyWhenRemoteIsNewerOrLocalFileIsMissing() async throws {
    let resource = WebDAVRemoteBookResource(
      name: "book.txt",
      url: try #require(URL(string: "https://dav.example/books/book.txt")),
      size: 12,
      lastModifiedMilliseconds: 2_000,
      isDirectory: false
    )
    let useCase = WebDAVRemoteBookRefreshUseCase(
      repository: RefreshProfileRepository(),
      transfer: RefreshTransfer(resource: resource)
    )
    let sourceID = AndroidWebDAVBookOrigin.encode(
      remoteURL: resource.url,
      serverID: 42
    )

    #expect(
      await useCase.check(
        sourceID: sourceID,
        lastCheckTime: 2_000,
        localFileAvailable: true
      ) == .current(remoteModifiedMilliseconds: 2_000)
    )
    guard case .downloadRequired = await useCase.check(
      sourceID: sourceID,
      lastCheckTime: 1_999,
      localFileAvailable: true
    ) else {
      Issue.record("Newer remote file must download")
      return
    }
    guard case .downloadRequired = await useCase.check(
      sourceID: sourceID,
      lastCheckTime: 9_999,
      localFileAvailable: false
    ) else {
      Issue.record("Missing local file must download regardless of timestamp")
      return
    }
  }
}

private actor RefreshProfileRepository: WebDAVServerProfileRepository {
  func webDAVServerProfiles() async throws -> [WebDAVServerProfile] {
    [
      WebDAVServerProfile(
        id: 42,
        name: "书库",
        serverAddress: "https://dav.example/books",
        sortNumber: 0,
        credentialReference: .init("server.42")
      )
    ]
  }
  func selectedWebDAVServerProfileID() async throws -> Int64? { nil }
  func replaceWebDAVServerProfiles(
    _ profiles: [WebDAVServerProfile],
    selectedID: Int64?
  ) async throws {}
}

private actor RefreshTransfer: WebDAVRemoteBookTransferring {
  let resource: WebDAVRemoteBookResource
  init(resource: WebDAVRemoteBookResource) { self.resource = resource }

  func listRemoteBooks(
    configuration: WebDAVConnectionConfiguration,
    directoryURL: URL?
  ) async -> WebDAVRemoteBookListResult { .loaded([]) }

  func downloadRemoteBook(
    configuration: WebDAVConnectionConfiguration,
    resource: WebDAVRemoteBookResource
  ) async -> WebDAVRemoteBookDownloadResult { .failed(.notFound) }

  func inspectRemoteBook(
    configuration: WebDAVConnectionConfiguration,
    remoteURL: URL
  ) async -> WebDAVRemoteBookInspectionResult { .found(resource) }
}
