import Foundation

public struct WebDAVBookIdentity: Sendable, Equatable, Hashable {
    public let name: String
    public let author: String

    public init(name: String, author: String) {
        self.name = name
        self.author = author
    }
}

public struct WebDAVBookProgressDocument: Codable, Sendable, Equatable {
    public let name: String
    public let author: String
    public let durChapterIndex: Int
    public let durChapterPos: Int
    public let durChapterTime: Int64
    public let durChapterTitle: String?

    public init(
        name: String,
        author: String,
        durChapterIndex: Int,
        durChapterPos: Int,
        durChapterTime: Int64,
        durChapterTitle: String?
    ) {
        self.name = name
        self.author = author
        self.durChapterIndex = durChapterIndex
        self.durChapterPos = durChapterPos
        self.durChapterTime = durChapterTime
        self.durChapterTitle = durChapterTitle
    }

    public var identity: WebDAVBookIdentity {
        WebDAVBookIdentity(name: name, author: author)
    }
}

public enum WebDAVBookProgressCodecError: Error, Sendable, Equatable {
    case invalidPayload
    case identityMismatch
}

public enum AndroidWebDAVBookProgressCodec {
    public static func decode(
        _ data: Data,
        expectedIdentity: WebDAVBookIdentity
    ) throws -> WebDAVBookProgressDocument {
        let document: WebDAVBookProgressDocument
        do {
            document = try JSONDecoder().decode(
                WebDAVBookProgressDocument.self,
                from: data
            )
        } catch {
            throw WebDAVBookProgressCodecError.invalidPayload
        }
        guard document.identity == expectedIdentity else {
            throw WebDAVBookProgressCodecError.identityMismatch
        }
        return document
    }

    public static func encode(
        _ document: WebDAVBookProgressDocument
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(document)
        } catch {
            throw WebDAVBookProgressCodecError.invalidPayload
        }
    }
}

public enum AndroidWebDAVBookProgressPath {
    private static let replacements: [(String, String)] = [
        ("%", "%25"),
        (" ", "%20"),
        ("\"", "%22"),
        ("#", "%23"),
        ("&", "%26"),
        ("(", "%28"),
        (")", "%29"),
        ("+", "%2B"),
        (",", "%2C"),
        ("/", "%2F"),
        (":", "%3A"),
        (";", "%3B"),
        ("<", "%3C"),
        ("=", "%3D"),
        (">", "%3E"),
        ("?", "%3F"),
        ("@", "%40"),
        ("\\", "%5C"),
        ("|", "%7C"),
    ]

    public static func encodedFileName(
        for identity: WebDAVBookIdentity
    ) -> String {
        var value = "\(identity.name)_\(identity.author)"
        for (reserved, encoded) in replacements {
            value = value.replacingOccurrences(of: reserved, with: encoded)
        }
        return value + ".json"
    }

    public static func url(
        configuration: WebDAVConnectionConfiguration,
        identity: WebDAVBookIdentity
    ) -> URL? {
        var filenameAllowed = CharacterSet.urlPathAllowed
        filenameAllowed.insert(charactersIn: "%")
        guard
            let rootURL = configuration.rootURL,
            let fileName = encodedFileName(for: identity)
                .addingPercentEncoding(
                    withAllowedCharacters: filenameAllowed
                ),
            var components = URLComponents(
                url: rootURL.appendingPathComponent(
                    "bookProgress",
                    isDirectory: true
                ),
                resolvingAgainstBaseURL: false
            )
        else {
            return nil
        }
        let separator = components.percentEncodedPath.hasSuffix("/") ? "" : "/"
        components.percentEncodedPath += separator + fileName
        return components.url
    }
}

public enum WebDAVBookProgressLoadFailure: Sendable, Equatable {
    case invalidConfiguration
    case credentialUnavailable
    case authenticationRejected
    case notFound
    case remoteRejected(statusCode: Int)
    case invalidPayload
    case identityMismatch
    case transportUnavailable
}

public enum WebDAVBookProgressLoadResult: Sendable, Equatable {
    case loaded(WebDAVBookProgressDocument)
    case failed(WebDAVBookProgressLoadFailure)
}

public protocol WebDAVBookProgressLoading: Sendable {
    func load(
        configuration: WebDAVConnectionConfiguration,
        identity: WebDAVBookIdentity
    ) async -> WebDAVBookProgressLoadResult
}

public enum WebDAVBookProgressSaveFailure: Sendable, Equatable {
    case invalidConfiguration
    case credentialUnavailable
    case authenticationRejected
    case remoteRejected(statusCode: Int)
    case invalidPayload
    case transportUnavailable
}

public enum WebDAVBookProgressSaveResult: Sendable, Equatable {
    case saved
    case failed(WebDAVBookProgressSaveFailure)
}

public protocol WebDAVBookProgressSaving: Sendable {
    func save(
        configuration: WebDAVConnectionConfiguration,
        document: WebDAVBookProgressDocument
    ) async -> WebDAVBookProgressSaveResult
}
