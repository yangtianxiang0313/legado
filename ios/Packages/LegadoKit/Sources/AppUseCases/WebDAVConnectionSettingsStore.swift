import Foundation
import IntegrationKit
import Observation

public struct WebDAVConnectionSettings: Codable, Equatable, Sendable {
    public var serverAddress: String
    public var directoryName: String
    public var credentialReference: WebDAVCredentialReference
    public var syncBookProgress: Bool

    public init(
        serverAddress: String = "",
        directoryName: String = "legado",
        credentialReference: WebDAVCredentialReference = .init("webdav.primary"),
        syncBookProgress: Bool = true
    ) {
        self.serverAddress = serverAddress
        self.directoryName = directoryName
        self.credentialReference = credentialReference
        self.syncBookProgress = syncBookProgress
    }

    private enum CodingKeys: String, CodingKey {
        case serverAddress
        case directoryName
        case credentialReference
        case syncBookProgress
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        serverAddress = try values.decodeIfPresent(
            String.self,
            forKey: .serverAddress
        ) ?? ""
        directoryName = try values.decodeIfPresent(
            String.self,
            forKey: .directoryName
        ) ?? "legado"
        credentialReference = try values.decodeIfPresent(
            WebDAVCredentialReference.self,
            forKey: .credentialReference
        ) ?? .init("webdav.primary")
        syncBookProgress = try values.decodeIfPresent(
            Bool.self,
            forKey: .syncBookProgress
        ) ?? true
    }
}

@MainActor
public protocol WebDAVConnectionSettingsRepository: AnyObject {
    func load() -> WebDAVConnectionSettings
    func save(_ settings: WebDAVConnectionSettings)
}

@MainActor
@Observable
public final class WebDAVConnectionSettingsStore {
    public private(set) var value: WebDAVConnectionSettings

    private let repository: any WebDAVConnectionSettingsRepository

    public init(repository: any WebDAVConnectionSettingsRepository) {
        self.repository = repository
        value = repository.load()
    }

    public func update(serverAddress: String, directoryName: String) {
        value.serverAddress = serverAddress
        value.directoryName = directoryName
        repository.save(value)
    }

    public func updateSyncBookProgress(_ enabled: Bool) {
        value.syncBookProgress = enabled
        repository.save(value)
    }

    public func replace(_ settings: WebDAVConnectionSettings) {
        value = settings
        repository.save(value)
    }
}
