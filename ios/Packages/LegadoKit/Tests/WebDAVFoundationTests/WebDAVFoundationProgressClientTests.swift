import Foundation
import IntegrationKit
import WebDAVFoundation
import XCTest

final class WebDAVFoundationProgressClientTests: XCTestCase {
    func testLoadsAndroidProgressWithExactIdentity() async throws {
        let body = Data(
            #"{"name":"SyncBook","author":"SyncAuthor","durChapterIndex":2,"durChapterPos":15,"durChapterTime":200,"durChapterTitle":"第三章"}"#.utf8
        )
        let transport = ProgressTransport(
            response: WebDAVHTTPDataResponse(statusCode: 200, body: body)
        )
        let client = WebDAVFoundationProgressClient(
            credentials: ProgressCredentials(),
            transport: transport
        )

        let result = await client.load(
            configuration: try configuration(),
            identity: identity
        )

        guard case .loaded(let document) = result else {
            return XCTFail("expected loaded progress, got \(result)")
        }
        XCTAssertEqual(2, document.durChapterIndex)
        let recordedRequest = await transport.request
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual("GET", request.httpMethod)
        XCTAssertEqual(
            "https://dav.example.test/dav/legado/bookProgress/SyncBook_SyncAuthor.json",
            request.url?.absoluteString
        )
        XCTAssertEqual("application/json", request.value(forHTTPHeaderField: "Accept"))
    }

    func testRejectsHTTPFailureBeforeParsingJSONBody() async throws {
        let client = WebDAVFoundationProgressClient(
            credentials: ProgressCredentials(),
            transport: ProgressTransport(
                response: WebDAVHTTPDataResponse(
                    statusCode: 404,
                    body: Data(#"{"status":404}"#.utf8)
                )
            )
        )

        let result = await client.load(
            configuration: try configuration(),
            identity: identity
        )
        XCTAssertEqual(.failed(.notFound), result)
    }

    func testRejectsAValidPayloadForAnotherBook() async throws {
        let body = Data(
            #"{"name":"Other","author":"SyncAuthor","durChapterIndex":9,"durChapterPos":9,"durChapterTime":9,"durChapterTitle":null}"#.utf8
        )
        let client = WebDAVFoundationProgressClient(
            credentials: ProgressCredentials(),
            transport: ProgressTransport(
                response: WebDAVHTTPDataResponse(statusCode: 200, body: body)
            )
        )

        let result = await client.load(
            configuration: try configuration(),
            identity: identity
        )
        XCTAssertEqual(.failed(.identityMismatch), result)
    }

    private let identity = WebDAVBookIdentity(
        name: "SyncBook",
        author: "SyncAuthor"
    )

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

private struct ProgressCredentials: WebDAVCredentialResolving {
    func credentials(for reference: WebDAVCredentialReference) async throws
        -> WebDAVBasicCredentials
    {
        WebDAVBasicCredentials(username: "reader", password: "secret")
    }
}

private actor ProgressTransport: WebDAVHTTPDataTransport {
    let response: WebDAVHTTPDataResponse
    private(set) var request: URLRequest?

    init(response: WebDAVHTTPDataResponse) {
        self.response = response
    }

    func performData(_ request: URLRequest) async throws
        -> WebDAVHTTPDataResponse
    {
        self.request = request
        return response
    }
}
