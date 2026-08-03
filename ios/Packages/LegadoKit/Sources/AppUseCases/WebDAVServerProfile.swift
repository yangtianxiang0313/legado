import Foundation
import IntegrationKit

public struct WebDAVServerProfile: Codable, Equatable, Sendable {
  public let id: Int64
  public let name: String
  public let serverAddress: String
  public let sortNumber: Int
  public let credentialReference: WebDAVCredentialReference

  public init(
    id: Int64,
    name: String,
    serverAddress: String,
    sortNumber: Int,
    credentialReference: WebDAVCredentialReference
  ) {
    self.id = id
    self.name = name
    self.serverAddress = serverAddress
    self.sortNumber = sortNumber
    self.credentialReference = credentialReference
  }

  public var connectionConfiguration: WebDAVConnectionConfiguration? {
    guard let serverURL = WebDAVServerURL(rawValue: serverAddress) else {
      return nil
    }
    return WebDAVConnectionConfiguration(
      serverURL: serverURL,
      directoryName: "",
      credentialReference: credentialReference
    )
  }
}

public protocol WebDAVServerProfileRepository: Sendable {
  func webDAVServerProfiles() async throws -> [WebDAVServerProfile]
  func selectedWebDAVServerProfileID() async throws -> Int64?
  func replaceWebDAVServerProfiles(
    _ profiles: [WebDAVServerProfile],
    selectedID: Int64?
  ) async throws
}
