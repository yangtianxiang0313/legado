import AppUseCases
import Foundation
import IntegrationKit
import Testing

@Suite("WebDAVLocalBookRecoveryTests")
struct WebDAVLocalBookRecoveryTests {
  @Test func decodesAndroidOriginAndUsesItsServerInsteadOfCurrentSelection() async throws {
    let profiles = [
      profile(id: 1, address: "https://other.invalid/books"),
      profile(id: 42, address: "https://dav.example/books"),
    ]
    let transfer = RecoveryTransferStub()
    let sourceID = AndroidWebDAVBookOrigin.encode(
      remoteURL: try #require(URL(string: "https://dav.example/books/%E8%AE%BA%E8%AF%AD.txt")),
      serverID: 42
    )

    let outcome = await WebDAVLocalBookRecoveryUseCase(
      repository: RecoveryProfileRepository(profiles: profiles),
      transfer: transfer
    ).recover(sourceID: sourceID, fallbackFileName: "论语.txt")

    guard case .recovered(
      let profileID,
      let fileName,
      let remoteURL,
      let data
    ) = outcome else {
      Issue.record("Expected recovered payload")
      return
    }
    #expect(profileID == 42)
    #expect(fileName == "论语.txt")
    #expect(remoteURL.host == "dav.example")
    #expect(data == Data("远端正文".utf8))
    #expect(await transfer.requestedConfiguration?.serverURL.rawValue == "https://dav.example/books/")
  }

  @Test func rejectsMalformedOriginBeforeNetwork() async {
    let transfer = RecoveryTransferStub()
    let outcome = await WebDAVLocalBookRecoveryUseCase(
      repository: RecoveryProfileRepository(profiles: []),
      transfer: transfer
    ).recover(
      sourceID: "webDav::https://dav.example/books/book.txt",
      fallbackFileName: "book.txt"
    )

    #expect(outcome == .invalidOrigin)
    #expect(await transfer.requestedConfiguration == nil)
  }

  @Test func treatsAndroidWebDAVOriginAsLocalBookSource() {
    #expect(AndroidWebDAVBookOrigin.isLocalSource("local-file"))
    #expect(AndroidWebDAVBookOrigin.isLocalSource("webDav::https://dav.invalid/book.txt,{\"serverID\":1}"))
    #expect(!AndroidWebDAVBookOrigin.isLocalSource("https://source.invalid"))
  }

  private func profile(id: Int64, address: String) -> WebDAVServerProfile {
    WebDAVServerProfile(
      id: id,
      name: "server-\(id)",
      serverAddress: address,
      sortNumber: Int(id),
      credentialReference: .init("server.\(id)")
    )
  }
}

private actor RecoveryProfileRepository: WebDAVServerProfileRepository {
  let profiles: [WebDAVServerProfile]

  init(profiles: [WebDAVServerProfile]) {
    self.profiles = profiles
  }

  func webDAVServerProfiles() async throws -> [WebDAVServerProfile] { profiles }
  func selectedWebDAVServerProfileID() async throws -> Int64? { 1 }
  func replaceWebDAVServerProfiles(
    _ profiles: [WebDAVServerProfile],
    selectedID: Int64?
  ) async throws {}
}

private actor RecoveryTransferStub: WebDAVRemoteBookTransferring {
  private(set) var requestedConfiguration: WebDAVConnectionConfiguration?

  func listRemoteBooks(
    configuration: WebDAVConnectionConfiguration,
    directoryURL: URL?
  ) async -> WebDAVRemoteBookListResult { .loaded([]) }

  func downloadRemoteBook(
    configuration: WebDAVConnectionConfiguration,
    resource: WebDAVRemoteBookResource
  ) async -> WebDAVRemoteBookDownloadResult {
    requestedConfiguration = configuration
    return .downloaded(name: resource.name, data: Data("远端正文".utf8))
  }
}
