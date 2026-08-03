import Foundation
import Security

public enum AndroidBackupPasswordStoreError: Error, Sendable {
  case unavailable(OSStatus)
  case invalidEncoding
}

public protocol AndroidBackupPasswordStoring: Sendable {
  func save(_ password: String) async throws
  func password() async throws -> String?
  func remove() async throws
}

public actor KeychainAndroidBackupPasswordStore:
  AndroidBackupPasswordStoring
{
  private let service: String
  private let account: String

  public init(
    service: String = "io.legado.android-backup.password",
    account: String = "local-password"
  ) {
    self.service = service
    self.account = account
  }

  public func save(_ password: String) throws {
    guard !password.isEmpty else {
      try remove()
      return
    }
    let query = keychainQuery()
    SecItemDelete(query as CFDictionary)
    var item = query
    item[kSecValueData as String] = Data(password.utf8)
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw AndroidBackupPasswordStoreError.unavailable(status)
    }
  }

  public func password() throws -> String? {
    var query = keychainQuery()
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else {
      throw AndroidBackupPasswordStoreError.unavailable(status)
    }
    guard let value = String(data: data, encoding: .utf8) else {
      throw AndroidBackupPasswordStoreError.invalidEncoding
    }
    return value
  }

  public func remove() throws {
    let status = SecItemDelete(keychainQuery() as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw AndroidBackupPasswordStoreError.unavailable(status)
    }
  }

  private func keychainQuery() -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }
}
