import Foundation
import IntegrationKit
import Testing
import WebDAVFoundation

@Suite("WebDAVRemoteBookRuntimeTests")
struct WebDAVRemoteBookRuntimeTests {
  @Test func listsDirectoriesAndAndroidSupportedBookFiles() async throws {
    let xml = """
      <d:multistatus xmlns:d="DAV:">
        <d:response><d:href>/dav/books/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>
        <d:response><d:href>/dav/books/%E5%8F%A4%E5%85%B8/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>
        <d:response><d:href>/dav/books/story.TXT</d:href><d:propstat><d:prop><d:getcontentlength>12</d:getcontentlength><d:getlastmodified>Tue, 04 Aug 2026 10:00:00 GMT</d:getlastmodified><d:resourcetype/></d:prop></d:propstat></d:response>
        <d:response><d:href>/dav/books/bundle.7z</d:href><d:propstat><d:prop><d:getcontentlength>21</d:getcontentlength><d:resourcetype/></d:prop></d:propstat></d:response>
        <d:response><d:href>/dav/books/cover.jpg</d:href><d:propstat><d:prop><d:resourcetype/></d:prop></d:propstat></d:response>
      </d:multistatus>
      """
    let transport = RemoteBookRecordingTransport(
      responses: [.init(statusCode: 207, body: Data(xml.utf8))]
    )
    let client = WebDAVFoundationRemoteBookClient(
      credentials: RemoteBookStaticCredentials(),
      transport: transport
    )

    let result = await client.listRemoteBooks(
      configuration: try configuration(),
      directoryURL: nil
    )
    guard case .loaded(let resources) = result else {
      Issue.record("expected loaded resources")
      return
    }
    #expect(resources.map(\.name) == ["古典", "story.TXT", "bundle.7z"])
    #expect(resources.map(\.isDirectory) == [true, false, false])
    #expect(resources.map(\.size) == [0, 12, 21])
    let request = try #require(await transport.requests.first)
    #expect(request.httpMethod == "PROPFIND")
    #expect(request.value(forHTTPHeaderField: "Depth") == "1")
    #expect(request.httpBody?.isEmpty == false)
  }

  @Test func downloadsExactBytesWithBasicAuthentication() async throws {
    let bytes = Data([0x50, 0x4B, 0x03, 0x04])
    let transport = RemoteBookRecordingTransport(
      responses: [.init(statusCode: 200, body: bytes)]
    )
    let client = WebDAVFoundationRemoteBookClient(
      credentials: RemoteBookStaticCredentials(),
      transport: transport
    )
    let resource = WebDAVRemoteBookResource(
      name: "book.zip",
      url: try #require(URL(string: "https://dav.example.test/dav/books/book.zip")),
      size: 4,
      lastModifiedMilliseconds: 0,
      isDirectory: false
    )

    let result = await client.downloadRemoteBook(
      configuration: try configuration(),
      resource: resource
    )
    #expect(result == .downloaded(name: "book.zip", data: bytes))
    let request = try #require(await transport.requests.first)
    #expect(request.httpMethod == "GET")
    #expect(
      request.value(forHTTPHeaderField: "Authorization")
        == "Basic cmVhZGVyOnNlY3JldA=="
    )
  }

  @Test func rejectsCrossHostResourceBeforeResolvingCredentials() async throws {
    let credentials = RemoteBookCountingCredentials()
    let transport = RemoteBookRecordingTransport(responses: [])
    let client = WebDAVFoundationRemoteBookClient(
      credentials: credentials,
      transport: transport
    )
    let resource = WebDAVRemoteBookResource(
      name: "book.txt",
      url: try #require(URL(string: "https://attacker.invalid/book.txt")),
      size: 0,
      lastModifiedMilliseconds: 0,
      isDirectory: false
    )

    let result = await client.downloadRemoteBook(
      configuration: try configuration(),
      resource: resource
    )
    #expect(result == .failed(.invalidResourceURL))
    #expect(await credentials.count == 0)
    #expect(await transport.requests.isEmpty)
  }

  @Test func mapsAuthenticationAndMalformedXMLFailures() async throws {
    let transport = RemoteBookRecordingTransport(
      responses: [
        .init(statusCode: 401, body: Data()),
        .init(statusCode: 207, body: Data("<broken>".utf8)),
      ]
    )
    let client = WebDAVFoundationRemoteBookClient(
      credentials: RemoteBookStaticCredentials(),
      transport: transport
    )
    let configuration = try configuration()

    #expect(
      await client.listRemoteBooks(
        configuration: configuration,
        directoryURL: nil
      ) == .failed(.authenticationRejected)
    )
    #expect(
      await client.listRemoteBooks(
        configuration: configuration,
        directoryURL: nil
      ) == .failed(.invalidResponse)
    )
  }

  private func configuration() throws -> WebDAVConnectionConfiguration {
    WebDAVConnectionConfiguration(
      serverURL: try #require(
        WebDAVServerURL(rawValue: "https://dav.example.test/dav")
      ),
      directoryName: "books",
      credentialReference: WebDAVCredentialReference("credential")
    )
  }
}

private struct RemoteBookStaticCredentials: WebDAVCredentialResolving {
  func credentials(
    for reference: WebDAVCredentialReference
  ) async throws -> WebDAVBasicCredentials {
    WebDAVBasicCredentials(username: "reader", password: "secret")
  }
}

private actor RemoteBookCountingCredentials: WebDAVCredentialResolving {
  private(set) var count = 0

  func credentials(
    for reference: WebDAVCredentialReference
  ) async throws -> WebDAVBasicCredentials {
    count += 1
    return WebDAVBasicCredentials(username: "reader", password: "secret")
  }
}

private actor RemoteBookRecordingTransport: WebDAVHTTPDataTransport {
  private var responses: [WebDAVHTTPDataResponse]
  private(set) var requests: [URLRequest] = []

  init(responses: [WebDAVHTTPDataResponse]) {
    self.responses = responses
  }

  func performData(_ request: URLRequest) async throws
    -> WebDAVHTTPDataResponse
  {
    requests.append(request)
    return responses.removeFirst()
  }
}
