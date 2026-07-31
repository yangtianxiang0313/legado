import Foundation
import IntegrationKit
import WebDAVFoundation
import XCTest

final class WebDAVFoundationConnectionClientTests: XCTestCase {
    func testInitializesRootAndAndroidNamedDirectories() async throws {
        let transport = RecordingTransport(statusCodes: [207, 207, 207, 207])
        let client = WebDAVFoundationConnectionClient(
            credentials: StaticCredentials(),
            transport: transport
        )

        let result = await client.initialize(try configuration())

        XCTAssertEqual(
            .ready(rootURL: try XCTUnwrap(URL(string: "https://dav.example.test/dav/legado/"))),
            result
        )
        let requests = await transport.requests
        XCTAssertEqual(["PROPFIND", "PROPFIND", "PROPFIND", "PROPFIND"], requests.map(\.httpMethod))
        XCTAssertEqual(["0", "0", "0", "0"], requests.map { $0.value(forHTTPHeaderField: "Depth") })
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Basic ") == true })
    }

    func testCreatesOnlyMissingDirectoryAfterProbe() async throws {
        let transport = RecordingTransport(statusCodes: [404, 201, 207, 207, 207])
        let client = WebDAVFoundationConnectionClient(
            credentials: StaticCredentials(),
            transport: transport
        )

        let result = await client.initialize(try configuration())
        XCTAssertEqual(
            .ready(
                rootURL: try XCTUnwrap(
                    URL(string: "https://dav.example.test/dav/legado/")
                )
            ),
            result
        )
        let requests = await transport.requests
        XCTAssertEqual(["PROPFIND", "MKCOL", "PROPFIND", "PROPFIND", "PROPFIND"], requests.map(\.httpMethod))
    }

    func testRejectsUnauthorizedCredentialsWithoutLeakingSecret() async throws {
        let client = WebDAVFoundationConnectionClient(
            credentials: StaticCredentials(),
            transport: RecordingTransport(statusCodes: [401])
        )

        let result = await client.initialize(try configuration())

        XCTAssertEqual(.failed(.authenticationRejected), result)
        XCTAssertFalse(String(describing: result).contains("p@ssword"))
    }

    func testTreatsMethodNotAllowedAsRemoteFailureInsteadOfAndroidCompatibilitySuccess() async throws {
        let client = WebDAVFoundationConnectionClient(
            credentials: StaticCredentials(),
            transport: RecordingTransport(statusCodes: [405])
        )

        let result = await client.initialize(try configuration())
        XCTAssertEqual(.failed(.remoteRejected(statusCode: 405)), result)
    }

    private func configuration() throws -> WebDAVConnectionConfiguration {
        WebDAVConnectionConfiguration(
            serverURL: try XCTUnwrap(WebDAVServerURL(rawValue: "https://dav.example.test/dav")),
            directoryName: "legado",
            credentialReference: WebDAVCredentialReference("credential-1")
        )
    }
}

private struct StaticCredentials: WebDAVCredentialResolving {
    func credentials(for reference: WebDAVCredentialReference) async throws -> WebDAVBasicCredentials {
        WebDAVBasicCredentials(username: "reader", password: "p@ssword")
    }
}

private actor RecordingTransport: WebDAVHTTPTransport {
    private let statusCodes: [Int]
    private var next = 0
    private(set) var requests: [URLRequest] = []

    init(statusCodes: [Int]) {
        self.statusCodes = statusCodes
    }

    func perform(_ request: URLRequest) async throws -> WebDAVHTTPResponse {
        requests.append(request)
        defer { next += 1 }
        return WebDAVHTTPResponse(statusCode: statusCodes[next])
    }
}
