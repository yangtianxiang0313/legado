import Foundation
import IntegrationKit
import Observation

public struct WebDAVServerProfile: Codable, Equatable, Sendable {
  public static let androidDefaultID: Int64 = -1

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

  public var isAndroidDefault: Bool { id == Self.androidDefaultID }
}

public enum WebDAVDefaultServerBridge {
  public static func profile(
    settings: WebDAVConnectionSettings
  ) -> WebDAVServerProfile? {
    guard
      let configuration = settings.connectionConfiguration,
      let rootURL = configuration.rootURL
    else { return nil }
    let booksURL = rootURL.appendingPathComponent(
      "books",
      isDirectory: true
    )
    return WebDAVServerProfile(
      id: WebDAVServerProfile.androidDefaultID,
      name: "默认 WebDAV",
      serverAddress: booksURL.absoluteString,
      sortNumber: Int.min,
      credentialReference: settings.credentialReference
    )
  }

  public static func androidExportProfiles(
    _ profiles: [WebDAVServerProfile]
  ) -> [WebDAVServerProfile] {
    profiles.filter { !$0.isAndroidDefault }
  }

  public static func androidExportSelectedID(_ id: Int64?) -> Int64? {
    id == WebDAVServerProfile.androidDefaultID ? nil : id
  }
}

public protocol WebDAVServerProfileRepository: Sendable {
  func webDAVServerProfiles() async throws -> [WebDAVServerProfile]
  func selectedWebDAVServerProfileID() async throws -> Int64?
  func replaceWebDAVServerProfiles(
    _ profiles: [WebDAVServerProfile],
    selectedID: Int64?
  ) async throws
  func upsertWebDAVServerProfile(_ profile: WebDAVServerProfile) async throws
  func selectWebDAVServerProfile(id: Int64?) async throws
}

public extension WebDAVServerProfileRepository {
  func selectWebDAVServerProfile(id: Int64?) async throws {}

  func upsertWebDAVServerProfile(
    _ profile: WebDAVServerProfile
  ) async throws {
    var profiles = try await webDAVServerProfiles()
    profiles.removeAll { $0.id == profile.id }
    profiles.append(profile)
    try await replaceWebDAVServerProfiles(
      profiles,
      selectedID: try await selectedWebDAVServerProfileID()
    )
  }
}

@MainActor
@Observable
public final class WebDAVRemoteBookBrowserStore {
  public private(set) var profiles: [WebDAVServerProfile] = []
  public private(set) var selectedProfileID: Int64?
  public private(set) var resources: [WebDAVRemoteBookResource] = []
  public private(set) var directoryStack: [WebDAVRemoteBookResource] = []
  public private(set) var isLoading = false
  public private(set) var statusMessage: String?

  private let repository: any WebDAVServerProfileRepository
  private let transfer: any WebDAVRemoteBookTransferring

  public init(
    repository: any WebDAVServerProfileRepository,
    transfer: any WebDAVRemoteBookTransferring
  ) {
    self.repository = repository
    self.transfer = transfer
  }

  public var selectedProfile: WebDAVServerProfile? {
    profiles.first { $0.id == selectedProfileID }
  }

  public var canNavigateBack: Bool { !directoryStack.isEmpty }

  public func load() async {
    do {
      profiles = try await repository.webDAVServerProfiles()
      let stored = try await repository.selectedWebDAVServerProfileID()
      selectedProfileID = profiles.contains { $0.id == stored }
        ? stored
        : profiles.first?.id
      guard selectedProfile != nil else {
        resources = []
        statusMessage = "没有可用的 WebDAV 服务器"
        return
      }
      await loadDirectory(nil, resetStack: true)
    } catch {
      statusMessage = "无法读取 WebDAV 服务器配置"
    }
  }

  public func selectProfile(id: Int64) async {
    guard profiles.contains(where: { $0.id == id }) else { return }
    do {
      try await repository.selectWebDAVServerProfile(id: id)
      selectedProfileID = id
      await loadDirectory(nil, resetStack: true)
    } catch {
      statusMessage = "无法切换 WebDAV 服务器"
    }
  }

  public func open(_ directory: WebDAVRemoteBookResource) async {
    guard directory.isDirectory else { return }
    await loadDirectory(directory, resetStack: false)
  }

  public func navigateBack() async {
    guard !directoryStack.isEmpty else { return }
    directoryStack.removeLast()
    await loadCurrentDirectory()
  }

  public func download(
    _ resource: WebDAVRemoteBookResource
  ) async -> (name: String, data: Data)? {
    guard
      !resource.isDirectory,
      let configuration = selectedProfile?.connectionConfiguration
    else { return nil }
    isLoading = true
    defer { isLoading = false }
    switch await transfer.downloadRemoteBook(
      configuration: configuration,
      resource: resource
    ) {
    case .downloaded(let name, let data):
      statusMessage = nil
      return (name, data)
    case .failed:
      statusMessage = "远程书下载失败"
      return nil
    }
  }

  private func loadDirectory(
    _ directory: WebDAVRemoteBookResource?,
    resetStack: Bool
  ) async {
    if resetStack {
      directoryStack = []
    } else if let directory {
      directoryStack.append(directory)
    }
    await loadCurrentDirectory()
  }

  private func loadCurrentDirectory() async {
    guard let configuration = selectedProfile?.connectionConfiguration else {
      resources = []
      statusMessage = "WebDAV 服务器地址无效"
      return
    }
    isLoading = true
    defer { isLoading = false }
    switch await transfer.listRemoteBooks(
      configuration: configuration,
      directoryURL: directoryStack.last?.url
    ) {
    case .loaded(let values):
      resources = values
      statusMessage = values.isEmpty ? "当前目录没有可导入书籍" : nil
    case .failed:
      resources = []
      statusMessage = "无法读取 WebDAV 目录"
    }
  }
}
