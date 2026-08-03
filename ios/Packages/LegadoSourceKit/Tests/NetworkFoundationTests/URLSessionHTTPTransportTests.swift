import Foundation
import NetworkFoundation
import SourceRuntime
import XCTest

final class URLSessionHTTPTransportTests: XCTestCase {
    func testMapsRequestAndPreservesEffectiveResponse() async throws {
        let loader = RecordingLoader(
            result: .success(
                (
                    Data("payload".utf8),
                    HTTPURLResponse(
                        url: URL(string: "https://example.com/final")!,
                        statusCode: 206,
                        httpVersion: "HTTP/1.1",
                        headerFields: [
                            "Content-Type": "text/plain",
                            "X-Trace": "network",
                        ]
                    )!
                )
            )
        )
        let transport = URLSessionHTTPTransport(loader: loader)
        let response = try await transport.execute(
            HTTPRequest(
                method: .post,
                url: try HTTPURL("https://example.com/start"),
                headers: HTTPHeaders([
                    try HTTPHeader(name: "X-Book", value: "one"),
                ]),
                body: HTTPBody(Data("request".utf8)),
                timeout: try HTTPTimeout(milliseconds: 2_500)
            )
        )

        let observedRequest = await loader.lastRequest()
        let request = try XCTUnwrap(observedRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-Book"),
            "one"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "User-Agent"),
            URLSessionHTTPTransport.androidCompatibleDefaultUserAgent
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Accept-Language"),
            URLSessionHTTPTransport.androidCompatibleDefaultAcceptLanguage
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Keep-Alive"),
            "300"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Connection"),
            "Keep-Alive"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Cache-Control"),
            "no-cache"
        )
        XCTAssertEqual(request.httpBody, Data("request".utf8))
        XCTAssertEqual(request.timeoutInterval, 2.5)
        XCTAssertEqual(response.statusCode, 206)
        XCTAssertEqual(
            response.effectiveURL.absoluteString,
            "https://example.com/final"
        )
        XCTAssertEqual(
            response.headers.values(for: "x-trace"),
            ["network"]
        )
        XCTAssertEqual(response.body.bytes, Data("payload".utf8))
    }

    func testPreservesExplicitAcceptLanguage() async throws {
        let loader = RecordingLoader(result: .success(okResponse()))
        let transport = URLSessionHTTPTransport(loader: loader)

        _ = try await transport.execute(
            HTTPRequest(
                method: .get,
                url: try HTTPURL("https://example.com"),
                headers: HTTPHeaders([
                    try HTTPHeader(
                        name: "Accept-Language",
                        value: "zh-TW"
                    ),
                ])
            )
        )

        let request = await loader.lastRequest()
        XCTAssertEqual(
            request?.value(forHTTPHeaderField: "Accept-Language"),
            "zh-TW"
        )
    }

    func testPreservesExplicitUserAgentAndRemovesNullSentinel()
        async throws
    {
        let explicitLoader = RecordingLoader(
            result: .success(okResponse())
        )
        let explicitTransport = URLSessionHTTPTransport(
            loader: explicitLoader
        )
        _ = try await explicitTransport.execute(
            HTTPRequest(
                method: .get,
                url: try HTTPURL("https://example.com"),
                headers: HTTPHeaders([
                    try HTTPHeader(
                        name: "User-Agent",
                        value: "Source Custom UA"
                    ),
                ])
            )
        )
        let explicitRequest = await explicitLoader.lastRequest()
        XCTAssertEqual(
            explicitRequest?.value(
                forHTTPHeaderField: "User-Agent"
            ),
            "Source Custom UA"
        )

        let nullLoader = RecordingLoader(
            result: .success(okResponse())
        )
        let nullTransport = URLSessionHTTPTransport(
            loader: nullLoader
        )
        _ = try await nullTransport.execute(
            HTTPRequest(
                method: .get,
                url: try HTTPURL("https://example.com"),
                headers: HTTPHeaders([
                    try HTTPHeader(
                        name: "User-Agent",
                        value: "null"
                    ),
                ])
            )
        )
        let nullRequest = await nullLoader.lastRequest()
        XCTAssertNil(
            nullRequest?.value(forHTTPHeaderField: "User-Agent")
        )
    }

    func testRejectsOversizedResponse() async throws {
        let loader = RecordingLoader(
            result: .success(
                (
                    Data(repeating: 1, count: 5),
                    HTTPURLResponse(
                        url: URL(string: "https://example.com")!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                )
            )
        )
        let transport = URLSessionHTTPTransport(
            loader: loader,
            maximumResponseBytes: 4
        )

        do {
            _ = try await transport.execute(request())
            XCTFail("Expected responseTooLarge")
        } catch let failure as HTTPTransportFailure {
            XCTAssertEqual(failure, .responseTooLarge)
        }
    }

    func testMapsTimeoutWithoutHidingCancellation() async throws {
        let timeout = URLSessionHTTPTransport(
            loader: RecordingLoader(
                result: .failure(URLError(.timedOut))
            )
        )
        do {
            _ = try await timeout.execute(request())
            XCTFail("Expected timeout")
        } catch let failure as HTTPTransportFailure {
            XCTAssertEqual(failure, .timeout)
        }

        let cancellation = URLSessionHTTPTransport(
            loader: RecordingLoader(
                result: .failure(CancellationError())
            )
        )
        do {
            _ = try await cancellation.execute(request())
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected: cancellation must cross the adapter unchanged.
        }
    }

    func testRejectsNonHTTPResponse() async throws {
        let loader = RecordingLoader(
            result: .success(
                (
                    Data(),
                    URLResponse(
                        url: URL(string: "https://example.com")!,
                        mimeType: nil,
                        expectedContentLength: 0,
                        textEncodingName: nil
                    )
                )
            )
        )
        let transport = URLSessionHTTPTransport(loader: loader)

        do {
            _ = try await transport.execute(request())
            XCTFail("Expected invalidResponse")
        } catch let failure as HTTPTransportFailure {
            XCTAssertEqual(failure, .invalidResponse)
        }
    }

    private func request() throws -> HTTPRequest {
        HTTPRequest(
            method: .get,
            url: try HTTPURL("https://example.com")
        )
    }

    private func okResponse() -> (Data, URLResponse) {
        (
            Data(),
            HTTPURLResponse(
                url: URL(string: "https://example.com")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
        )
    }
}

private actor RecordingLoader: URLSessionDataLoading {
    private let result: Result<URLSessionLoadResult, any Error>
    private var observedRequest: URLRequest?

    init(result: Result<(Data, URLResponse), any Error>) {
        self.result = result.map {
            URLSessionLoadResult(data: $0.0, response: $0.1)
        }
    }

    func data(
        for request: URLRequest,
        proxy: HTTPProxyConfiguration?
    ) async throws -> URLSessionLoadResult {
        observedRequest = request
        return try result.get()
    }

    func lastRequest() -> URLRequest? {
        observedRequest
    }
}
