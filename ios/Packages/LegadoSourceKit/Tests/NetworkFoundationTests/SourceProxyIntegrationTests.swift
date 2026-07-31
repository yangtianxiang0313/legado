import Foundation
@testable import NetworkFoundation
@testable import SourceRuntime
import XCTest

final class SourceProxyIntegrationTests: XCTestCase {
    func testSourceControlHeaderBecomesRequestPolicyWithoutHeaderLeak()
        async throws
    {
        let base = HTTPRequest(
            method: .get,
            url: try HTTPURL("https://books.example/search")
        )
        let prepared = try SourceRequestPreparer.prepare(
            request: base,
            inheritedHeaders: [
                try SourceHeaderField(
                    name: "proxy",
                    value: "http://127.0.0.1:18080@reader@secret"
                ),
                try SourceHeaderField(
                    name: "X-Source",
                    value: "production"
                ),
            ],
            optionHeaders: [],
            persistentCookie: "",
            enabledCookieJar: false,
            retry: 0
        )

        let expected = HTTPProxyConfiguration(
            type: .http,
            host: "127.0.0.1",
            port: 18_080,
            username: "reader",
            password: "secret"
        )
        XCTAssertEqual(prepared.proxy, expected)
        XCTAssertEqual(prepared.constructedRequest.proxy, expected)
        XCTAssertEqual(prepared.networkRequest.proxy, expected)
        XCTAssertFalse(
            prepared.constructedHeaders.contains {
                $0.name.caseInsensitiveCompare("proxy")
                    == .orderedSame
            }
        )
        XCTAssertTrue(
            prepared.constructedRequest.headers.values(
                for: "proxy"
            ).isEmpty
        )
        let encodedRequest = try JSONEncoder().encode(
            prepared.constructedRequest
        )
        let encodedText = String(
            decoding: encodedRequest,
            as: UTF8.self
        )
        XCTAssertFalse(encodedText.contains("reader"))
        XCTAssertFalse(encodedText.contains("secret"))

        let store = SourceCookieStore()
        let cookiePrepared =
            try await SourceCookieRequestCoordinator.prepare(
                request: prepared.networkRequest,
                storageURL: base.url,
                explicitCookie: "session=one",
                store: store,
                enabledCookieJar: true
            )
        XCTAssertEqual(
            cookiePrepared.resolvedRequest.proxy,
            expected
        )
        XCTAssertEqual(
            cookiePrepared.networkRequest.proxy,
            expected
        )
    }

    func testDispatchCompilerCarriesSOCKSPolicyOnNetworkRequest()
        throws
    {
        let plan = try SourceTransportDispatchCompiler.compile(
            SourceTransportDispatchInput(
                url: "https://books.example/catalog",
                inheritedHeaders: [
                    try SourceHeaderField(
                        name: "proxy",
                        value: "socks5://localhost:1080"
                    ),
                ],
                returnKind: .response
            )
        )

        XCTAssertEqual(
            plan.request?.proxy,
            HTTPProxyConfiguration(
                type: .socks,
                host: "localhost",
                port: 1_080
            )
        )
        XCTAssertTrue(
            plan.request?.headers.values(for: "proxy").isEmpty
                == true
        )
    }

    func testTransportPassesPolicyBesideURLRequest() async throws {
        let loader = ProxyRecordingLoader()
        let transport = URLSessionHTTPTransport(loader: loader)
        let proxy = HTTPProxyConfiguration(
            type: .http,
            host: "proxy.example",
            port: 8_080
        )

        _ = try await transport.execute(
            HTTPRequest(
                method: .get,
                url: try HTTPURL("https://books.example/search"),
                proxy: proxy
            )
        )

        let observedProxy = await loader.lastProxy()
        let observedRequest = await loader.lastRequest()
        XCTAssertEqual(observedProxy, proxy)
        let urlRequest = try XCTUnwrap(observedRequest)
        XCTAssertNil(
            urlRequest.value(forHTTPHeaderField: "proxy")
        )
    }

    func testFoundationDictionaryMapsHTTPAndAuthenticatedSOCKS()
        throws
    {
        let http =
            URLSessionProxyConfigurationBuilder.dictionary(
                for: HTTPProxyConfiguration(
                    type: .http,
                    host: "http.proxy",
                    port: 8_080
                )
        )
        XCTAssertEqual(
            http["HTTPProxy"] as? String,
            "http.proxy"
        )
        XCTAssertEqual(
            http["HTTPSPort"] as? Int,
            8_080
        )

        let socks =
            URLSessionProxyConfigurationBuilder.dictionary(
                for: HTTPProxyConfiguration(
                    type: .socks,
                    host: "socks.proxy",
                    port: 1_080,
                    username: "reader",
                    password: "secret"
                )
        )
        XCTAssertEqual(
            socks["SOCKSProxy"] as? String,
            "socks.proxy"
        )
        XCTAssertEqual(
            socks["SOCKSUser"] as? String,
            "reader"
        )
        XCTAssertEqual(
            socks["SOCKSPassword"] as? String,
            "secret"
        )
    }

    func testInvalidAndroidProxySyntaxFailsClosed() {
        for value in [
            "https://proxy.example:8080",
            "http://proxy.example",
            "http://proxy.example:70000",
            "http://proxy.example:8080@reader",
        ] {
            XCTAssertThrowsError(
                try SourceProxyConfiguration(value)
            ) { error in
                XCTAssertEqual(
                    error as? SourceTransportDispatchError,
                    .invalidProxy
                )
            }
        }
    }
}

private actor ProxyRecordingLoader: URLSessionDataLoading {
    private var request: URLRequest?
    private var proxy: HTTPProxyConfiguration?

    func data(
        for request: URLRequest,
        proxy: HTTPProxyConfiguration?
    ) async throws -> URLSessionLoadResult {
        self.request = request
        self.proxy = proxy
        return URLSessionLoadResult(
            data: Data(),
            response: HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
        )
    }

    func lastRequest() -> URLRequest? {
        request
    }

    func lastProxy() -> HTTPProxyConfiguration? {
        proxy
    }
}
