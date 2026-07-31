import Foundation
import IntegrationKit
import XCTest

final class WebDAVConnectionTests: XCTestCase {
    func testNormalizesServerAndDirectoryIntoRequiredDirectories() throws {
        let server = try XCTUnwrap(
            WebDAVServerURL(rawValue: " https://dav.example.test/dav ")
        )
        let configuration = WebDAVConnectionConfiguration(
            serverURL: server,
            directoryName: " /legado/ ",
            credentialReference: WebDAVCredentialReference("credential-1")
        )

        XCTAssertEqual("https://dav.example.test/dav/", server.rawValue)
        XCTAssertEqual(
            [
                "https://dav.example.test/dav/legado/",
                "https://dav.example.test/dav/legado/bookProgress/",
                "https://dav.example.test/dav/legado/books/",
                "https://dav.example.test/dav/legado/background/",
            ],
            configuration.requiredDirectoryURLs.map(\.absoluteString)
        )
    }

    func testRejectsNonHTTPServerURL() {
        XCTAssertNil(WebDAVServerURL(rawValue: "dav://example.test/root"))
        XCTAssertNil(WebDAVServerURL(rawValue: "example.test/root"))
    }
}
