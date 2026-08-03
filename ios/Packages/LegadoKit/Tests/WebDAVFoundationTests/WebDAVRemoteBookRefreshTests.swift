import Foundation
import IntegrationKit
import Testing
import WebDAVFoundation

@Suite("WebDAVRemoteBookRefreshTests")
struct WebDAVRemoteBookRefreshFoundationTests {
  @Test func inspectsExactResourceWithDepthZero() async throws {
    let xml = """
      <d:multistatus xmlns:d="DAV:"><d:response><d:href>/dav/books/book.txt</d:href><d:propstat><d:prop><d:getcontentlength>12</d:getcontentlength><d:getlastmodified>Tue, 04 Aug 2026 10:00:00 GMT</d:getlastmodified><d:resourcetype/></d:prop></d:propstat></d:response></d:multistatus>
      """
    let transport = RefreshRecordingTransport(
      response: .init(statusCode: 207, body: Data(xml.utf8))
    )
    let client = WebDAVFoundationRemoteBookClient(
      credentials: RefreshCredentials(),
      transport: transport
    )
    let configuration = WebDAVConnectionConfiguration(
      serverURL: try #require(WebDAVServerURL(rawValue: "https://dav.example/dav")),
      directoryName: "books",
      credentialReference: .init("credential")
    )
    let url = try #require(URL(string: "https://dav.example/dav/books/book.txt"))

    let result = await client.inspectRemoteBook(
      configuration: configuration,
      remoteURL: url
    )

    guard case .found(let resource) = result else {
      Issue.record("Expected remote resource")
      return
    }
    #expect(resource.name == "book.txt")
    #expect(resource.size == 12)
    #expect(resource.lastModifiedMilliseconds > 0)
    #expect(await transport.request?.httpMethod == "PROPFIND")
    #expect(await transport.request?.value(forHTTPHeaderField: "Depth") == "0")
  }

  @Test func mapsNotFoundWithoutParsingBody() async throws {
    let client = WebDAVFoundationRemoteBookClient(
      credentials: RefreshCredentials(),
      transport: RefreshRecordingTransport(
        response: .init(statusCode: 404, body: Data())
      )
    )
    let configuration = WebDAVConnectionConfiguration(
      serverURL: try #require(WebDAVServerURL(rawValue: "https://dav.example/dav")),
      directoryName: "books",
      credentialReference: .init("credential")
    )
    #expect(
      await client.inspectRemoteBook(
        configuration: configuration,
        remoteURL: try #require(URL(string: "https://dav.example/dav/books/missing.txt"))
      ) == .missing
    )
  }
}

private struct RefreshCredentials: WebDAVCredentialResolving {
  func credentials(
    for reference: WebDAVCredentialReference
  ) async throws -> WebDAVBasicCredentials {
    .init(username: "reader", password: "secret")
  }
}

private actor RefreshRecordingTransport: WebDAVHTTPDataTransport {
  let response: WebDAVHTTPDataResponse
  private(set) var request: URLRequest?

  init(response: WebDAVHTTPDataResponse) {
    self.response = response
  }

  func performData(_ request: URLRequest) async throws -> WebDAVHTTPDataResponse {
    self.request = request
    return response
  }
}
