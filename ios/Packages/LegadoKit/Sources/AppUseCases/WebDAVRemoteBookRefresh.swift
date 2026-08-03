import Foundation
import IntegrationKit

public struct WebDAVRemoteBookRefreshTarget: Sendable, Equatable {
  public let configuration: WebDAVConnectionConfiguration
  public let resource: WebDAVRemoteBookResource

  public init(
    configuration: WebDAVConnectionConfiguration,
    resource: WebDAVRemoteBookResource
  ) {
    self.configuration = configuration
    self.resource = resource
  }
}

public enum WebDAVRemoteBookRefreshDecision: Sendable, Equatable {
  case current(remoteModifiedMilliseconds: Int64)
  case downloadRequired(WebDAVRemoteBookRefreshTarget)
  case remoteMissing
  case notWebDAVBook
  case invalidOrigin
  case serverProfileUnavailable
  case invalidServerProfile
  case repositoryUnavailable
  case failed(WebDAVRemoteBookFailure)
}

public struct WebDAVRemoteBookRefreshUseCase: Sendable {
  private let repository: any WebDAVServerProfileRepository
  private let transfer: any WebDAVRemoteBookTransferring

  public init(
    repository: any WebDAVServerProfileRepository,
    transfer: any WebDAVRemoteBookTransferring
  ) {
    self.repository = repository
    self.transfer = transfer
  }

  public func check(
    sourceID: String,
    lastCheckTime: Int64,
    localFileAvailable: Bool
  ) async -> WebDAVRemoteBookRefreshDecision {
    guard sourceID.hasPrefix(AndroidWebDAVBookOrigin.prefix) else {
      return .notWebDAVBook
    }
    guard let origin = AndroidWebDAVBookOrigin.decode(sourceID) else {
      return .invalidOrigin
    }
    let profiles: [WebDAVServerProfile]
    do {
      profiles = try await repository.webDAVServerProfiles()
    } catch {
      return .repositoryUnavailable
    }
    guard let profile = profiles.first(where: { $0.id == origin.serverID }) else {
      return .serverProfileUnavailable
    }
    guard let configuration = profile.connectionConfiguration else {
      return .invalidServerProfile
    }
    switch await transfer.inspectRemoteBook(
      configuration: configuration,
      remoteURL: origin.remoteURL
    ) {
    case .found(let resource):
      if
        !localFileAvailable
          || resource.lastModifiedMilliseconds > max(0, lastCheckTime)
      {
        return .downloadRequired(
          WebDAVRemoteBookRefreshTarget(
            configuration: configuration,
            resource: resource
          )
        )
      }
      return .current(
        remoteModifiedMilliseconds: resource.lastModifiedMilliseconds
      )
    case .missing:
      return .remoteMissing
    case .failed(let failure):
      return .failed(failure)
    }
  }
}
