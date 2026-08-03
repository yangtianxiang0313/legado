import Foundation
import IntegrationKit

public struct WebDAVBasicCredentials: Sendable, Equatable {
    public let username: String
    public let password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

public protocol WebDAVCredentialResolving: Sendable {
    func credentials(
        for reference: WebDAVCredentialReference
    ) async throws -> WebDAVBasicCredentials
}

public struct WebDAVHTTPResponse: Sendable, Equatable {
    public let statusCode: Int

    public init(statusCode: Int) {
        self.statusCode = statusCode
    }
}

public protocol WebDAVHTTPTransport: Sendable {
    func perform(_ request: URLRequest) async throws -> WebDAVHTTPResponse
}

public struct URLSessionWebDAVTransport: WebDAVHTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func perform(_ request: URLRequest) async throws -> WebDAVHTTPResponse {
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return WebDAVHTTPResponse(statusCode: http.statusCode)
    }
}

public struct WebDAVFoundationConnectionClient: WebDAVConnectionInitializing {
    private let credentials: any WebDAVCredentialResolving
    private let transport: any WebDAVHTTPTransport

    public init(
        credentials: any WebDAVCredentialResolving,
        transport: any WebDAVHTTPTransport = URLSessionWebDAVTransport()
    ) {
        self.credentials = credentials
        self.transport = transport
    }

    public func initialize(
        _ configuration: WebDAVConnectionConfiguration
    ) async -> WebDAVConnectionInitialization {
        guard let rootURL = configuration.rootURL else {
            return .failed(.invalidConfiguration)
        }
        let resolvedCredentials: WebDAVBasicCredentials
        do {
            resolvedCredentials = try await credentials.credentials(
                for: configuration.credentialReference
            )
        } catch {
            return .failed(.credentialUnavailable)
        }

        for directoryURL in configuration.requiredDirectoryURLs {
            let result = await ensureDirectory(
                directoryURL,
                credentials: resolvedCredentials
            )
            if case let .failed(failure) = result {
                return .failed(failure)
            }
        }
        return .ready(rootURL: rootURL)
    }

    private func ensureDirectory(
        _ url: URL,
        credentials: WebDAVBasicCredentials
    ) async -> WebDAVConnectionInitialization {
        do {
            let probe = try await transport.perform(
                request(
                    url: url,
                    method: "PROPFIND",
                    credentials: credentials,
                    depth: "0"
                )
            )
            switch probe.statusCode {
            case 200 ... 299:
                return .ready(rootURL: url)
            case 401:
                return .failed(.authenticationRejected)
            case 404:
                let create = try await transport.perform(
                    request(
                        url: url,
                        method: "MKCOL",
                        credentials: credentials,
                        depth: nil
                    )
                )
                switch create.statusCode {
                case 200 ... 299:
                    return .ready(rootURL: url)
                case 401:
                    return .failed(.authenticationRejected)
                default:
                    return .failed(.remoteRejected(statusCode: create.statusCode))
                }
            default:
                return .failed(.remoteRejected(statusCode: probe.statusCode))
            }
        } catch {
            return .failed(.transportUnavailable)
        }
    }

    private func request(
        url: URL,
        method: String,
        credentials: WebDAVBasicCredentials,
        depth: String?
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let depth {
            request.setValue(depth, forHTTPHeaderField: "Depth")
        }
        let rawAuthorization = "\(credentials.username):\(credentials.password)"
        let encoded = Data(rawAuthorization.utf8).base64EncodedString()
        request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
        return request
    }
}
