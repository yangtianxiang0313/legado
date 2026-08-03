import Foundation
import IntegrationKit

public enum WebDAVLocalBookUploadOutcome: Sendable, Equatable {
  case uploaded(
    profileID: Int64,
    serverName: String,
    fileName: String,
    remoteURL: URL
  )
  case noServerProfile
  case localFileUnavailable
  case invalidServerProfile
  case repositoryUnavailable
  case failed(WebDAVRemoteBookFailure)
}

public struct WebDAVLocalBookUploadUseCase: Sendable {
  private let repository: any WebDAVServerProfileRepository
  private let transfer: any WebDAVRemoteBookTransferring

  public init(
    repository: any WebDAVServerProfileRepository,
    transfer: any WebDAVRemoteBookTransferring
  ) {
    self.repository = repository
    self.transfer = transfer
  }

  public func upload(
    fileName: String,
    data: Data
  ) async -> WebDAVLocalBookUploadOutcome {
    let profiles: [WebDAVServerProfile]
    let selectedID: Int64?
    do {
      profiles = try await repository.webDAVServerProfiles()
      selectedID = try await repository.selectedWebDAVServerProfileID()
    } catch {
      return .repositoryUnavailable
    }
    guard !profiles.isEmpty else { return .noServerProfile }
    let profile = profiles.first { $0.id == selectedID } ?? profiles[0]
    guard let configuration = profile.connectionConfiguration else {
      return .invalidServerProfile
    }
    switch await transfer.uploadRemoteBook(
      configuration: configuration,
      fileName: fileName,
      data: data
    ) {
    case .uploaded(let uploadedName, let remoteURL):
      return .uploaded(
        profileID: profile.id,
        serverName: profile.name,
        fileName: uploadedName,
        remoteURL: remoteURL
      )
    case .failed(let failure):
      return .failed(failure)
    }
  }
}
