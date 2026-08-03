import Foundation
import IntegrationKit
import WebDAVFoundation
import XCTest

final class WebDAVFoundationBackupClientTests: XCTestCase {
  func testListsOnlyBackupFilesUsingAndroidHrefNames() async throws {
    let xml = """
    <d:multistatus xmlns:d="DAV:">
      <d:response><d:href>/dav/legado/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>
      <d:response><d:href>/dav/legado/backup2026-08-03.zip</d:href><d:propstat><d:prop><d:displayname>ignored.zip</d:displayname><d:getcontentlength>12</d:getcontentlength><d:getlastmodified>Mon, 03 Aug 2026 10:00:00 GMT</d:getlastmodified><d:resourcetype/></d:prop></d:propstat></d:response>
      <d:response><d:href>/dav/legado/backup%202026-08-04.zip</d:href><d:propstat><d:prop><d:getcontentlength>21</d:getcontentlength><d:getlastmodified>Tue, 04 Aug 2026 10:00:00 GMT</d:getlastmodified><d:resourcetype/></d:prop></d:propstat></d:response>
      <d:response><d:href>/dav/legado/notes.txt</d:href><d:propstat><d:prop><d:resourcetype/></d:prop></d:propstat></d:response>
    </d:multistatus>
    """
    let transport = BackupRecordingTransport(
      responses: [.init(statusCode: 207, body: Data(xml.utf8))]
    )
    let client = WebDAVFoundationBackupClient(
      credentials: BackupStaticCredentials(),
      transport: transport
    )

    let result = await client.listBackups(configuration: try configuration())

    guard case .loaded(let files) = result else {
      return XCTFail("expected files, got \(result)")
    }
    XCTAssertEqual(
      ["backup 2026-08-04.zip", "backup2026-08-03.zip"],
      files.map(\.name)
    )
    XCTAssertEqual([21, 12], files.map(\.size))
    let requests = await transport.requests
    XCTAssertEqual("PROPFIND", requests.first?.httpMethod)
    XCTAssertEqual("1", requests.first?.value(forHTTPHeaderField: "Depth"))
  }

  func testUploadsExactArchiveBytesWithAndroidMediaType() async throws {
    let transport = BackupRecordingTransport(
      responses: [.init(statusCode: 201, body: Data())]
    )
    let client = WebDAVFoundationBackupClient(
      credentials: BackupStaticCredentials(),
      transport: transport
    )
    let archive = Data([0x50, 0x4B, 0x03, 0x04])

    let result = await client.uploadBackup(
      configuration: try configuration(),
      fileName: "backup2026-08-04.zip",
      data: archive
    )

    XCTAssertEqual(.uploaded, result)
    let requests = await transport.requests
    let request = try XCTUnwrap(requests.first)
    XCTAssertEqual("PUT", request.httpMethod)
    XCTAssertEqual(archive, request.httpBody)
    XCTAssertEqual(
      "application/octet-stream",
      request.value(forHTTPHeaderField: "Content-Type")
    )
  }

  func testDownloadsBytesAndMapsNotFound() async throws {
    let archive = Data([0x50, 0x4B])
    let transport = BackupRecordingTransport(
      responses: [
        .init(statusCode: 200, body: archive),
        .init(statusCode: 404, body: Data()),
      ]
    )
    let client = WebDAVFoundationBackupClient(
      credentials: BackupStaticCredentials(),
      transport: transport
    )
    let configuration = try configuration()

    let downloaded = await client.downloadBackup(
      configuration: configuration,
      fileName: "backup2026-08-04.zip"
    )
    let missing = await client.downloadBackup(
      configuration: configuration,
      fileName: "backup2026-08-03.zip"
    )
    XCTAssertEqual(.downloaded(archive), downloaded)
    XCTAssertEqual(.failed(.notFound), missing)
  }

  private func configuration() throws -> WebDAVConnectionConfiguration {
    WebDAVConnectionConfiguration(
      serverURL: try XCTUnwrap(
        WebDAVServerURL(rawValue: "https://dav.example.test/dav")
      ),
      directoryName: "legado",
      credentialReference: WebDAVCredentialReference("credential")
    )
  }
}

private struct BackupStaticCredentials: WebDAVCredentialResolving {
  func credentials(
    for reference: WebDAVCredentialReference
  ) async throws -> WebDAVBasicCredentials {
    WebDAVBasicCredentials(username: "reader", password: "secret")
  }
}

private actor BackupRecordingTransport: WebDAVHTTPDataTransport {
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
