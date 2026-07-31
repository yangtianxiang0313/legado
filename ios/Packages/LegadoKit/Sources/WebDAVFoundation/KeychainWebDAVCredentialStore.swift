import Foundation
import IntegrationKit
import Security

public enum WebDAVCredentialStoreError: Error, Sendable {
    case unavailable
}

public actor KeychainWebDAVCredentialStore: WebDAVCredentialResolving {
    private let service: String

    public init(service: String = "io.legado.webdav.credentials") {
        self.service = service
    }

    public func save(
        _ credentials: WebDAVBasicCredentials,
        for reference: WebDAVCredentialReference
    ) throws {
        let query = keychainQuery(reference: reference)
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = try JSONEncoder().encode(
            StoredCredentials(credentials)
        )
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
            throw WebDAVCredentialStoreError.unavailable
        }
    }

    public func credentials(
        for reference: WebDAVCredentialReference
    ) async throws -> WebDAVBasicCredentials {
        var query = keychainQuery(reference: reference)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard
            SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data,
            let stored = try? JSONDecoder().decode(
                StoredCredentials.self,
                from: data
            )
        else {
            throw WebDAVCredentialStoreError.unavailable
        }
        return WebDAVBasicCredentials(
            username: stored.username,
            password: stored.password
        )
    }

    public func remove(
        reference: WebDAVCredentialReference
    ) {
        SecItemDelete(keychainQuery(reference: reference) as CFDictionary)
    }

    private func keychainQuery(
        reference: WebDAVCredentialReference
    ) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference.rawValue,
        ]
    }
}

private struct StoredCredentials: Codable {
    let username: String
    let password: String

    init(_ credentials: WebDAVBasicCredentials) {
        username = credentials.username
        password = credentials.password
    }
}
