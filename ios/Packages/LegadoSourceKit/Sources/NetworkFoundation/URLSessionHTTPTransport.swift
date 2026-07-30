import Foundation
import SourceRuntime

public protocol URLSessionDataLoading: Sendable {
    func data(for request: URLRequest) async throws -> (
        Data,
        URLResponse
    )
}

extension URLSession: URLSessionDataLoading {}

public actor URLSessionHTTPTransport: HTTPTransport {
    public static let defaultMaximumResponseBytes = 32 * 1_024 * 1_024

    private let loader: any URLSessionDataLoading
    private let maximumResponseBytes: Int

    public init(
        configuration: URLSessionConfiguration = .default,
        maximumResponseBytes: Int = defaultMaximumResponseBytes
    ) {
        let isolated = configuration.copy()
            as? URLSessionConfiguration ?? configuration
        isolated.httpCookieStorage = nil
        isolated.httpShouldSetCookies = false
        isolated.urlCache = nil
        isolated.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.loader = URLSession(configuration: isolated)
        self.maximumResponseBytes = max(0, maximumResponseBytes)
    }

    public init(
        loader: any URLSessionDataLoading,
        maximumResponseBytes: Int = defaultMaximumResponseBytes
    ) {
        self.loader = loader
        self.maximumResponseBytes = max(0, maximumResponseBytes)
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
        for header in request.headers.fields {
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
            let (data, response) = try await loader.data(for: urlRequest)
            try Task.checkCancellation()
            guard data.count <= maximumResponseBytes else {
                throw HTTPTransportFailure.responseTooLarge
            }
            guard let http = response as? HTTPURLResponse else {
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
                body: HTTPBody(data)
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
