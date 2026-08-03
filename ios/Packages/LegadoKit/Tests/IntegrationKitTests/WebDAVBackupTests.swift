import IntegrationKit
import XCTest

final class WebDAVBackupTests: XCTestCase {
  func testBuildsAndroidRootBackupPath() throws {
    let url = AndroidWebDAVBackupPath.fileURL(
      configuration: try configuration(),
      fileName: "backup2026-08-04-iPhone.zip"
    )
    XCTAssertEqual(
      "https://dav.example.test/dav/legado/backup2026-08-04-iPhone.zip",
      url?.absoluteString
    )
  }

  func testRejectsTraversalAndNonBackupNames() throws {
    let configuration = try configuration()
    XCTAssertNil(
      AndroidWebDAVBackupPath.fileURL(
        configuration: configuration,
        fileName: "../backup.zip"
      )
    )
    XCTAssertNil(
      AndroidWebDAVBackupPath.fileURL(
        configuration: configuration,
        fileName: "library.zip"
      )
    )
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
