import Foundation
@testable import NetworkFoundation
import SourceRuntime
import XCTest

final class NetworkRedirectCookieTests: XCTestCase {
    func testCollectorKeepsRedirectAndFinalCookieOrigins() throws {
        let collector = RedirectCookieCollector()
        let redirectURL = URL(
            string: "https://start.example/login"
        )!
        let redirect = try XCTUnwrap(
            HTTPURLResponse(
                url: redirectURL,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Location": "https://auth.example/home",
                    "Set-Cookie": "sid=one; Path=/",
                ]
            )
        )
        let followUp = URLRequest(
            url: URL(string: "https://auth.example/home")!
        )
        var acceptedFollowUp: URLRequest?
        let task = URLSession.shared.dataTask(with: redirectURL)
        collector.urlSession(
            URLSession.shared,
            task: task,
            willPerformHTTPRedirection: redirect,
            newRequest: followUp
        ) {
            acceptedFollowUp = $0
        }

        XCTAssertEqual(acceptedFollowUp?.url, followUp.url)
        XCTAssertEqual(
            collector.snapshot(),
            [
                HTTPResponseCookie(
                    originURL: try HTTPURL(redirectURL.absoluteString),
                    name: "sid",
                    value: "one",
                    isPersistent: false
                ),
            ]
        )

        let finalURL = URL(
            string: "https://auth.example/home"
        )!
        let final = try XCTUnwrap(
            HTTPURLResponse(
                url: finalURL,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Set-Cookie":
                        "token=two; Max-Age=3600; Path=/",
                ]
            )
        )
        XCTAssertEqual(
            URLSessionResponseCookieExtractor.cookies(from: final),
            [
                HTTPResponseCookie(
                    originURL: try HTTPURL(finalURL.absoluteString),
                    name: "token",
                    value: "two",
                    isPersistent: true
                ),
            ]
        )
    }

    func testSourceSessionPersistsCookiesByOriginForNextRequest()
        async throws
    {
        let startURL = try HTTPURL(
            "https://start.example/login"
        )
        let finalURL = try HTTPURL(
            "https://auth.example/home"
        )
        let firstLoader = CookieChainLoader(
            result: URLSessionLoadResult(
                data: Data("ok".utf8),
                response: HTTPURLResponse(
                    url: URL(string: finalURL.absoluteString)!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil
                )!,
                responseCookies: [
                    HTTPResponseCookie(
                        originURL: startURL,
                        name: "sid",
                        value: "one",
                        isPersistent: false
                    ),
                    HTTPResponseCookie(
                        originURL: finalURL,
                        name: "token",
                        value: "two",
                        isPersistent: true
                    ),
                ]
            )
        )
        let store = SourceCookieStore()
        _ = try await SourceRequestSession(
            transport: URLSessionHTTPTransport(
                loader: firstLoader
            ),
            cookieStore: store
        ).execute(
            plan(url: startURL),
            enabledCookieJar: true
        )

        let startSnapshot = try await store.snapshot(for: startURL)
        XCTAssertEqual(startSnapshot.sessionCookie, "sid=one")
        XCTAssertEqual(startSnapshot.persistentCookie, "")
        let finalSnapshot = try await store.snapshot(for: finalURL)
        XCTAssertEqual(finalSnapshot.sessionCookie, nil)
        XCTAssertEqual(finalSnapshot.persistentCookie, "token=two")

        let secondLoader = CookieChainLoader(
            result: URLSessionLoadResult(
                data: Data(),
                response: HTTPURLResponse(
                    url: URL(string: finalURL.absoluteString)!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        )
        _ = try await SourceRequestSession(
            transport: URLSessionHTTPTransport(
                loader: secondLoader
            ),
            cookieStore: store
        ).execute(
            plan(
                url: try HTTPURL(
                    "https://auth.example/books"
                )
            ),
            enabledCookieJar: true
        )
        let observedRequest = await secondLoader.lastRequest()
        let nextRequest = try XCTUnwrap(observedRequest)
        XCTAssertEqual(
            nextRequest.value(forHTTPHeaderField: "Cookie"),
            "token=two"
        )
    }

    private func plan(url: HTTPURL) -> SourceRequestPlan {
        SourceRequestPlan(
            request: HTTPRequest(method: .get, url: url),
            body: nil,
            formFields: []
        )
    }
}

private actor CookieChainLoader: URLSessionDataLoading {
    private let result: URLSessionLoadResult
    private var request: URLRequest?

    init(result: URLSessionLoadResult) {
        self.result = result
    }

    func data(
        for request: URLRequest,
        proxy: HTTPProxyConfiguration?
    ) async throws -> URLSessionLoadResult {
        self.request = request
        return result
    }

    func lastRequest() -> URLRequest? {
        request
    }
}
