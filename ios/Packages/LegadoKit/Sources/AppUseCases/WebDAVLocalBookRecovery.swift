import Foundation
import IntegrationKit

public enum WebDAVLocalBookRecoveryOutcome: Sendable, Equatable {
  case recovered(
    profileID: Int64,
    fileName: String,
    remoteURL: URL,
    data: Data
  )
  case notWebDAVBook
  case invalidOrigin
  case serverProfileUnavailable
  case invalidServerProfile
  case repositoryUnavailable
  case failed(WebDAVRemoteBookFailure)
}

public struct WebDAVLocalBookRecoveryUseCase: Sendable {
  private let repository: any WebDAVServerProfileRepository
  private let transfer: any WebDAVRemoteBookTransferring

  public init(
    repository: any WebDAVServerProfileRepository,
    transfer: any WebDAVRemoteBookTransferring
  ) {
    self.repository = repository
    self.transfer = transfer
  }

  public func recover(
    sourceID: String,
    fallbackFileName: String
  ) async -> WebDAVLocalBookRecoveryOutcome {
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
    let remoteName = origin.remoteURL.lastPathComponent
    let resource = WebDAVRemoteBookResource(
      name: remoteName.isEmpty ? fallbackFileName : remoteName,
      url: origin.remoteURL,
      size: 0,
      lastModifiedMilliseconds: 0,
      isDirectory: false
    )
    switch await transfer.downloadRemoteBook(
      configuration: configuration,
      resource: resource
    ) {
    case .downloaded(let name, let data):
      return .recovered(
        profileID: profile.id,
        fileName: name.isEmpty ? fallbackFileName : name,
        remoteURL: origin.remoteURL,
        data: data
      )
    case .failed(let failure):
      return .failed(failure)
    }
  }
}
