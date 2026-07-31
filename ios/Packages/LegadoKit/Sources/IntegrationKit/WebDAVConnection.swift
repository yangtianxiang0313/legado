import Foundation

public struct WebDAVCredentialReference: Codable, Sendable, Equatable, Hashable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct WebDAVServerURL: Sendable, Equatable, Hashable {
    public let rawValue: String

    public init?(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let url = URL(string: trimmed),
            let scheme = url.scheme?.lowercased(),
            scheme == "https" || scheme == "http",
            url.host != nil
        else {
            return nil
        }
        self.rawValue = trimmed.hasSuffix("/") ? trimmed : trimmed + "/"
    }
}

public struct WebDAVConnectionConfiguration: Sendable, Equatable {
    public static let requiredDirectoryNames = [
        "bookProgress",
        "books",
        "background",
    ]

    public let serverURL: WebDAVServerURL
    public let directoryName: String
    public let credentialReference: WebDAVCredentialReference

    public init(
        serverURL: WebDAVServerURL,
        directoryName: String,
        credentialReference: WebDAVCredentialReference
    ) {
        self.serverURL = serverURL
        self.directoryName = directoryName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.credentialReference = credentialReference
    }

    public var rootURL: URL? {
        guard let server = URL(string: serverURL.rawValue) else { return nil }
        guard !directoryName.isEmpty else { return server }
        return server.appendingPathComponent(directoryName, isDirectory: true)
    }

    public var requiredDirectoryURLs: [URL] {
        guard let rootURL else { return [] }
        return [rootURL] + Self.requiredDirectoryNames.compactMap {
            rootURL.appendingPathComponent($0, isDirectory: true)
        }
    }
}

public enum WebDAVConnectionFailure: Sendable, Equatable {
    case invalidConfiguration
    case credentialUnavailable
    case authenticationRejected
    case remoteRejected(statusCode: Int)
    case transportUnavailable
}

public enum WebDAVConnectionInitialization: Sendable, Equatable {
    case ready(rootURL: URL)
    case failed(WebDAVConnectionFailure)
}

public protocol WebDAVConnectionInitializing: Sendable {
    func initialize(
        _ configuration: WebDAVConnectionConfiguration
    ) async -> WebDAVConnectionInitialization
}
