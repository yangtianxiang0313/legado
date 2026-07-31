import Foundation
import IntegrationKit
import Observation

public struct WebDAVConnectionSettings: Codable, Equatable, Sendable {
    public var serverAddress: String
    public var directoryName: String
    public var credentialReference: WebDAVCredentialReference

    public init(
        serverAddress: String = "",
        directoryName: String = "legado",
        credentialReference: WebDAVCredentialReference = .init("webdav.primary")
    ) {
        self.serverAddress = serverAddress
        self.directoryName = directoryName
        self.credentialReference = credentialReference
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
}
