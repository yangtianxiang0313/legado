import Foundation
@testable import NetworkFoundation
import SourceRuntime
import XCTest

final class ProductionGZIPIntegrationTests: XCTestCase {
    func testFoundationDetectionDistinguishesDecodedAndWireBytes()
        throws
    {
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: URL(
                    string: "https://books.example/gzip"
                )!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Encoding": "gzip"
                ]
            )
        )
        XCTAssertTrue(
            URLSessionContentEncodingNormalizer
                .wasTransparentlyDecoded(
                    data: Data("decoded".utf8),
                    response: response
                )
        )
        XCTAssertFalse(
            URLSessionContentEncodingNormalizer
                .wasTransparentlyDecoded(
                    data: Data([0x1F, 0x8B, 0x08]),
                    response: response
                )
        )
    }

    func testDecodedFoundationBodyDropsStaleEncodingMetadata()
        async throws
    {
        let decoded = Data("GZIP：星河\n".utf8)
        let loader = GZIPLoader(
            data: decoded,
            bodyIsContentDecoded: true
        )
        let response = try await URLSessionHTTPTransport(
            loader: loader
        ).execute(request())

        XCTAssertTrue(
            response.headers.values(
                for: "content-encoding"
            ).isEmpty
        )
        XCTAssertTrue(
            response.headers.values(
                for: "content-length"
            ).isEmpty
        )
        XCTAssertEqual(
            try SourceStringResponseNormalizer
                .normalize(response).body,
            "GZIP：星河\n"
        )
    }

    func testCompressedFixtureRetainsEncodingAndUsesPortableDecoder()
        async throws
    {
        let compressed = try XCTUnwrap(
            Data(
                base64Encoded:
                    "H4sIAAAAAAAC/3OP8gx4v2fWsxnzn23azAUAlX93HQ4AAAA="
            )
        )
        let loader = GZIPLoader(
            data: compressed,
            bodyIsContentDecoded: false
        )
        let response = try await URLSessionHTTPTransport(
            loader: loader
        ).execute(request())

        XCTAssertEqual(
            response.headers.values(
                for: "content-encoding"
            ),
            ["gzip"]
        )
        XCTAssertEqual(
            try SourceStringResponseNormalizer
                .normalize(response).body,
            "GZIP：星河\n"
        )
    }

    private func request() throws -> HTTPRequest {
        HTTPRequest(
            method: .get,
            url: try HTTPURL(
                "https://books.example/gzip"
            )
        )
    }
}

private actor GZIPLoader: URLSessionDataLoading {
    let data: Data
    let bodyIsContentDecoded: Bool

    init(
        data: Data,
        bodyIsContentDecoded: Bool
    ) {
        self.data = data
        self.bodyIsContentDecoded = bodyIsContentDecoded
    }

    func data(
        for request: URLRequest,
        proxy: HTTPProxyConfiguration?
    ) async throws -> URLSessionLoadResult {
        URLSessionLoadResult(
            data: data,
            response: HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type":
                        "text/plain; charset=utf-8",
                    "Content-Encoding": "gzip",
                    "Content-Length": "34",
                ]
            )!,
            bodyIsContentDecoded:
                bodyIsContentDecoded
        )
    }
}
