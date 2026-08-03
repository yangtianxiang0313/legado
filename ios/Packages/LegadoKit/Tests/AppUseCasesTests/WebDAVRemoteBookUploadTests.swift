import AppUseCases
import Foundation
import IntegrationKit
import Testing

@Suite("WebDAVRemoteBookUploadTests")
struct WebDAVRemoteBookUploadUseCaseTests {
  @Test func uploadsThroughSelectedAndroidServerProfile() async throws {
    let profiles = [
      profile(id: 1, name: "备用", address: "https://backup.invalid/books"),
      profile(id: 2, name: "主书库", address: "https://dav.example/books"),
    ]
    let repository = UploadProfileRepository(
      profiles: profiles,
      selectedID: 2
    )
    let transfer = UploadTransferStub()
    let useCase = WebDAVLocalBookUploadUseCase(
      repository: repository,
      transfer: transfer
    )

    let outcome = await useCase.upload(
      fileName: "论语.txt",
      data: Data("正文".utf8)
    )

    guard case .uploaded(
      let profileID,
      let serverName,
      let fileName,
      let remoteURL
    ) = outcome else {
      Issue.record("Expected selected profile upload")
      return
    }
    #expect(profileID == 2)
    #expect(serverName == "主书库")
    #expect(fileName == "论语.txt")
    #expect(remoteURL.absoluteString.contains("dav.example"))
    let request = try #require(await transfer.uploads.first)
    #expect(request.configuration.serverURL.rawValue == "https://dav.example/books/")
    #expect(request.data == Data("正文".utf8))
  }

  @Test func reportsMissingServerWithoutCallingTransfer() async {
    let transfer = UploadTransferStub()
    let outcome = await WebDAVLocalBookUploadUseCase(
      repository: UploadProfileRepository(profiles: [], selectedID: nil),
      transfer: transfer
    ).upload(fileName: "book.txt", data: Data())

    #expect(outcome == .noServerProfile)
    #expect(await transfer.uploads.isEmpty)
  }

  private func profile(
    id: Int64,
    name: String,
    address: String
  ) -> WebDAVServerProfile {
    WebDAVServerProfile(
      id: id,
      name: name,
      serverAddress: address,
      sortNumber: Int(id),
      credentialReference: .init("webdav.server.\(id)")
    )
  }
}

private actor UploadProfileRepository: WebDAVServerProfileRepository {
  private let profiles: [WebDAVServerProfile]
  private let selectedID: Int64?

  init(profiles: [WebDAVServerProfile], selectedID: Int64?) {
    self.profiles = profiles
    self.selectedID = selectedID
  }

  func webDAVServerProfiles() async throws -> [WebDAVServerProfile] {
    profiles
  }

  func selectedWebDAVServerProfileID() async throws -> Int64? {
    selectedID
  }

  func replaceWebDAVServerProfiles(
    _ profiles: [WebDAVServerProfile],
    selectedID: Int64?
  ) async throws {}
}

private actor UploadTransferStub: WebDAVRemoteBookTransferring {
  struct Upload: Sendable {
    let configuration: WebDAVConnectionConfiguration
    let fileName: String
    let data: Data
  }

  private(set) var uploads: [Upload] = []

  func listRemoteBooks(
    configuration: WebDAVConnectionConfiguration,
    directoryURL: URL?
  ) async -> WebDAVRemoteBookListResult {
    .loaded([])
  }

  func downloadRemoteBook(
    configuration: WebDAVConnectionConfiguration,
    resource: WebDAVRemoteBookResource
  ) async -> WebDAVRemoteBookDownloadResult {
    .failed(.notFound)
  }

  func uploadRemoteBook(
    configuration: WebDAVConnectionConfiguration,
    fileName: String,
    data: Data
  ) async -> WebDAVRemoteBookUploadResult {
    uploads.append(
      Upload(
        configuration: configuration,
        fileName: fileName,
        data: data
      )
    )
    return .uploaded(
      name: fileName,
      remoteURL: configuration.rootURL!.appendingPathComponent(fileName)
    )
  }
}
