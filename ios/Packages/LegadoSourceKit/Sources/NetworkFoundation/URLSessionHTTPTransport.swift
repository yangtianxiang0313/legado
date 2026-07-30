import Foundation
import os
import SourceRuntime

public struct URLSessionLoadResult: Sendable {
    public let data: Data
    public let response: URLResponse
    public let responseCookies: [HTTPResponseCookie]

    public init(
        data: Data,
        response: URLResponse,
        responseCookies: [HTTPResponseCookie] = []
    ) {
        self.data = data
        self.response = response
        self.responseCookies = responseCookies
    }
}

public protocol URLSessionDataLoading: Sendable {
    func data(for request: URLRequest) async throws
        -> URLSessionLoadResult
}

public actor URLSessionHTTPTransport: HTTPTransport {
    public static let defaultMaximumResponseBytes = 32 * 1_024 * 1_024
    public static let androidCompatibleDefaultUserAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) "
        + "Chrome/123.0.0.0 Safari/537.36"

    private let loader: any URLSessionDataLoading
    private let maximumResponseBytes: Int
    private let defaultUserAgent: String

    public init(
        configuration: URLSessionConfiguration = .default,
        maximumResponseBytes: Int = defaultMaximumResponseBytes,
        defaultUserAgent: String = androidCompatibleDefaultUserAgent
    ) {
        let isolated = configuration.copy()
            as? URLSessionConfiguration ?? configuration
        isolated.httpCookieStorage = nil
        isolated.httpShouldSetCookies = false
        isolated.urlCache = nil
        isolated.requestCachePolicy = .reloadIgnoringLocalCacheData
        isolated.timeoutIntervalForRequest = 15
        isolated.timeoutIntervalForResource = 60
        self.loader = FoundationURLSessionDataLoader(
            configuration: isolated
        )
        self.maximumResponseBytes = max(0, maximumResponseBytes)
        self.defaultUserAgent = defaultUserAgent
    }

    public init(
        loader: any URLSessionDataLoading,
        maximumResponseBytes: Int = defaultMaximumResponseBytes,
        defaultUserAgent: String = androidCompatibleDefaultUserAgent
    ) {
        self.loader = loader
        self.maximumResponseBytes = max(0, maximumResponseBytes)
        self.defaultUserAgent = defaultUserAgent
    }

    public func execute(
        _ request: HTTPRequest
    ) async throws -> HTTPResponse {
        try Task.checkCancellation()
        guard let url = URL(string: request.url.absoluteString) else {
            throw HTTPTransportFailure.invalidRequest
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        var fields = request.headers.fields
        let userAgent = fields.last(where: {
            $0.name == "user-agent"
        })?.value
        fields.removeAll {
            $0.name == "user-agent" && userAgent == "null"
        }
        if userAgent == nil {
            fields.append(
                try HTTPHeader(
                    name: "User-Agent",
                    value: defaultUserAgent
                )
            )
        }
        fields.append(
            contentsOf: [
                try HTTPHeader(name: "Keep-Alive", value: "300"),
                try HTTPHeader(
                    name: "Connection",
                    value: "Keep-Alive"
                ),
                try HTTPHeader(
                    name: "Cache-Control",
                    value: "no-cache"
                ),
            ]
        )
        for header in fields {
            urlRequest.addValue(
                header.value,
                forHTTPHeaderField: header.name
            )
        }
        urlRequest.httpBody = request.body?.bytes
        if let timeout = request.timeout {
            urlRequest.timeoutInterval =
                TimeInterval(timeout.milliseconds) / 1_000
        }

        do {
            let result = try await loader.data(for: urlRequest)
            try Task.checkCancellation()
            guard result.data.count <= maximumResponseBytes else {
                throw HTTPTransportFailure.responseTooLarge
            }
            guard let http = result.response as? HTTPURLResponse else {
                throw HTTPTransportFailure.invalidResponse
            }
            let responseHeaders = HTTPHeaders(
                http.allHeaderFields.compactMap { key, value in
                    guard let name = key as? String else { return nil }
                    return try? HTTPHeader(
                        name: name,
                        value: String(describing: value)
                    )
                }.sorted {
                    $0.name == $1.name
                        ? $0.value < $1.value
                        : $0.name < $1.name
                }
            )
            return try HTTPResponse(
                statusCode: http.statusCode,
                effectiveURL: HTTPURL(
                    http.url?.absoluteString
                        ?? request.url.absoluteString
                ),
                headers: responseHeaders,
                body: HTTPBody(result.data),
                responseCookies: result.responseCookies
            )
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch let failure as HTTPTransportFailure {
            throw failure
        } catch let error as URLError {
            if Task.isCancelled || error.code == .cancelled {
                throw CancellationError()
            }
            switch error.code {
            case .timedOut:
                throw HTTPTransportFailure.timeout
            case .badURL, .unsupportedURL:
                throw HTTPTransportFailure.invalidRequest
            default:
                throw HTTPTransportFailure.connectionFailed
            }
        } catch {
            try Task.checkCancellation()
            throw HTTPTransportFailure.connectionFailed
        }
    }
}

private actor FoundationURLSessionDataLoader:
    URLSessionDataLoading
{
    private let session: URLSession

    init(configuration: URLSessionConfiguration) {
        self.session = URLSession(configuration: configuration)
    }

    func data(
        for request: URLRequest
    ) async throws -> URLSessionLoadResult {
        let collector = RedirectCookieCollector()
        let (data, response) = try await session.data(
            for: request,
            delegate: collector
        )
        var cookies = collector.snapshot()
        if let http = response as? HTTPURLResponse {
            cookies.append(
                contentsOf:
                    URLSessionResponseCookieExtractor.cookies(
                        from: http
                    )
            )
        }
        return URLSessionLoadResult(
            data: data,
            response: response,
            responseCookies: cookies
        )
    }
}

final class RedirectCookieCollector:
    NSObject,
    URLSessionTaskDelegate
{
    private let storage = OSAllocatedUnfairLock(
        initialState: [HTTPResponseCookie]()
    )

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let cookies = URLSessionResponseCookieExtractor.cookies(
            from: response
        )
        storage.withLock {
            $0.append(contentsOf: cookies)
        }
        completionHandler(request)
    }

    func snapshot() -> [HTTPResponseCookie] {
        storage.withLock { $0 }
    }
}

enum URLSessionResponseCookieExtractor {
    static func cookies(
        from response: HTTPURLResponse
    ) -> [HTTPResponseCookie] {
        guard
            let url = response.url,
            let originURL = try? HTTPURL(url.absoluteString)
        else {
            return []
        }
        var fields: [String: String] = [:]
        for (rawName, rawValue) in response.allHeaderFields {
            guard let name = rawName as? String else { continue }
            fields[name] = String(describing: rawValue)
        }
        return HTTPCookie.cookies(
            withResponseHeaderFields: fields,
            for: url
        ).map {
            HTTPResponseCookie(
                originURL: originURL,
                name: $0.name,
                value: $0.value,
                isPersistent: !$0.isSessionOnly
            )
        }
    }
}
