import Foundation
import IntegrationKit
import Testing
import WebDAVFoundation

@Suite("WebDAVRemoteBookUploadTests")
struct WebDAVRemoteBookUploadTests {
  @Test func uploadsExactBytesToAndroidBookRoot() async throws {
    let transport = UploadRecordingTransport(statusCode: 201)
    let client = WebDAVFoundationRemoteBookClient(
      credentials: UploadStaticCredentials(),
      transport: transport
    )
    let data = Data("正文".utf8)

    let result = await client.uploadRemoteBook(
      configuration: try configuration(),
      fileName: "论语.txt",
      data: data
    )

    let request = try #require(await transport.requests.first)
    #expect(request.httpMethod == "PUT")
    #expect(request.url?.absoluteString == "https://dav.example.test/dav/books/%E8%AE%BA%E8%AF%AD.txt")
    #expect(request.httpBody == data)
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic cmVhZGVyOnNlY3JldA==")
    #expect(result == .uploaded(name: "论语.txt", remoteURL: try #require(request.url)))
  }

  @Test func rejectsPathLikeFileNameBeforeCredentialsAndTransport() async throws {
    let credentials = UploadCountingCredentials()
    let transport = UploadRecordingTransport(statusCode: 201)
    let client = WebDAVFoundationRemoteBookClient(
      credentials: credentials,
      transport: transport
    )

    let result = await client.uploadRemoteBook(
      configuration: try configuration(),
      fileName: "../book.txt",
      data: Data()
    )

    #expect(result == .failed(.invalidFileName))
    #expect(await credentials.count == 0)
    #expect(await transport.requests.isEmpty)
  }

  @Test func mapsRemoteRejection() async throws {
    let client = WebDAVFoundationRemoteBookClient(
      credentials: UploadStaticCredentials(),
      transport: UploadRecordingTransport(statusCode: 507)
    )
    #expect(
      await client.uploadRemoteBook(
        configuration: try configuration(),
        fileName: "book.txt",
        data: Data()
      ) == .failed(.remoteRejected(statusCode: 507))
    )
  }

  private func configuration() throws -> WebDAVConnectionConfiguration {
    WebDAVConnectionConfiguration(
      serverURL: try #require(
        WebDAVServerURL(rawValue: "https://dav.example.test/dav")
      ),
      directoryName: "books",
      credentialReference: .init("credential")
    )
  }
}

private struct UploadStaticCredentials: WebDAVCredentialResolving {
  func credentials(
    for reference: WebDAVCredentialReference
  ) async throws -> WebDAVBasicCredentials {
    .init(username: "reader", password: "secret")
  }
}

private actor UploadCountingCredentials: WebDAVCredentialResolving {
  private(set) var count = 0

  func credentials(
    for reference: WebDAVCredentialReference
  ) async throws -> WebDAVBasicCredentials {
    count += 1
    return .init(username: "reader", password: "secret")
  }
}

private actor UploadRecordingTransport: WebDAVHTTPDataTransport {
  private let statusCode: Int
  private(set) var requests: [URLRequest] = []

  init(statusCode: Int) {
    self.statusCode = statusCode
  }

  func performData(_ request: URLRequest) async throws -> WebDAVHTTPDataResponse {
    requests.append(request)
    return .init(statusCode: statusCode, body: Data())
  }
}
