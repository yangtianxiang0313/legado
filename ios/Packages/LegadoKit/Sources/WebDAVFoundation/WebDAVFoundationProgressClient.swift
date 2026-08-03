import Foundation
import IntegrationKit

public struct WebDAVHTTPDataResponse: Sendable, Equatable {
    public let statusCode: Int
    public let body: Data

    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }
}

public protocol WebDAVHTTPDataTransport: Sendable {
    func performData(_ request: URLRequest) async throws
        -> WebDAVHTTPDataResponse
}

public struct URLSessionWebDAVDataTransport: WebDAVHTTPDataTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func performData(_ request: URLRequest) async throws
        -> WebDAVHTTPDataResponse
    {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return WebDAVHTTPDataResponse(
            statusCode: http.statusCode,
            body: data
        )
    }
}

public struct WebDAVFoundationProgressClient:
    WebDAVBookProgressLoading,
    WebDAVBookProgressSaving
{
    private let credentials: any WebDAVCredentialResolving
    private let transport: any WebDAVHTTPDataTransport

    public init(
        credentials: any WebDAVCredentialResolving,
        transport: any WebDAVHTTPDataTransport = URLSessionWebDAVDataTransport()
    ) {
        self.credentials = credentials
        self.transport = transport
    }

    public func load(
        configuration: WebDAVConnectionConfiguration,
        identity: WebDAVBookIdentity
    ) async -> WebDAVBookProgressLoadResult {
        guard
            let url = AndroidWebDAVBookProgressPath.url(
                configuration: configuration,
                identity: identity
            )
        else {
            return .failed(.invalidConfiguration)
        }
        let resolved: WebDAVBasicCredentials
        do {
            resolved = try await credentials.credentials(
                for: configuration.credentialReference
            )
        } catch {
            return .failed(.credentialUnavailable)
        }

        do {
            let response = try await transport.performData(
                request(url: url, credentials: resolved)
            )
            switch response.statusCode {
            case 200 ... 299:
                break
            case 401:
                return .failed(.authenticationRejected)
            case 404:
                return .failed(.notFound)
            default:
                return .failed(
                    .remoteRejected(statusCode: response.statusCode)
                )
            }
            do {
                return .loaded(
                    try AndroidWebDAVBookProgressCodec.decode(
                        response.body,
                        expectedIdentity: identity
                    )
                )
            } catch WebDAVBookProgressCodecError.identityMismatch {
                return .failed(.identityMismatch)
            } catch {
                return .failed(.invalidPayload)
            }
        } catch {
            return .failed(.transportUnavailable)
        }
    }

    public func save(
        configuration: WebDAVConnectionConfiguration,
        document: WebDAVBookProgressDocument
    ) async -> WebDAVBookProgressSaveResult {
        guard
            let url = AndroidWebDAVBookProgressPath.url(
                configuration: configuration,
                identity: document.identity
            )
        else {
            return .failed(.invalidConfiguration)
        }
        let body: Data
        do {
            body = try AndroidWebDAVBookProgressCodec.encode(document)
        } catch {
            return .failed(.invalidPayload)
        }
        let resolved: WebDAVBasicCredentials
        do {
            resolved = try await credentials.credentials(
                for: configuration.credentialReference
            )
        } catch {
            return .failed(.credentialUnavailable)
        }

        do {
            let response = try await transport.performData(
                saveRequest(
                    url: url,
                    credentials: resolved,
                    body: body
                )
            )
            switch response.statusCode {
            case 200 ... 299:
                return .saved
            case 401:
                return .failed(.authenticationRejected)
            default:
                return .failed(
                    .remoteRejected(statusCode: response.statusCode)
                )
            }
        } catch {
            return .failed(.transportUnavailable)
        }
    }

    private func request(
        url: URL,
        credentials: WebDAVBasicCredentials
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let raw = "\(credentials.username):\(credentials.password)"
        request.setValue(
            "Basic \(Data(raw.utf8).base64EncodedString())",
            forHTTPHeaderField: "Authorization"
        )
        return request
    }

    private func saveRequest(
        url: URL,
        credentials: WebDAVBasicCredentials,
        body: Data
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = body
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        let raw = "\(credentials.username):\(credentials.password)"
        request.setValue(
            "Basic \(Data(raw.utf8).base64EncodedString())",
            forHTTPHeaderField: "Authorization"
        )
        return request
    }
}
