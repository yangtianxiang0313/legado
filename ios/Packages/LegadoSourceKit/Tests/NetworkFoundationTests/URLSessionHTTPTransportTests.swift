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
}

private actor RecordingLoader: URLSessionDataLoading {
    private let result: Result<(Data, URLResponse), any Error>
    private var observedRequest: URLRequest?

    init(result: Result<(Data, URLResponse), any Error>) {
        self.result = result
    }

    func data(
        for request: URLRequest
    ) async throws -> (Data, URLResponse) {
        observedRequest = request
        return try result.get()
    }

    func lastRequest() -> URLRequest? {
        observedRequest
    }
}
