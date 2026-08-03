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
  func deleteWebDAVServerProfile(id: Int64) async throws
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

  func deleteWebDAVServerProfile(id: Int64) async throws {
    let profiles = try await webDAVServerProfiles().filter { $0.id != id }
    let selectedID = try await selectedWebDAVServerProfileID()
    try await replaceWebDAVServerProfiles(
      profiles,
      selectedID: selectedID == id ? profiles.first?.id : selectedID
    )
  }
}

public struct WebDAVServerCredential: Equatable, Sendable {
  public let username: String
  public let password: String

  public init(username: String, password: String) {
    self.username = username
    self.password = password
  }
}

public protocol WebDAVServerCredentialVault: Sendable {
  func credential(
    for reference: WebDAVCredentialReference
  ) async -> WebDAVServerCredential?
  func save(
    _ credential: WebDAVServerCredential,
    for reference: WebDAVCredentialReference
  ) async throws
  func remove(reference: WebDAVCredentialReference) async
}

public enum WebDAVServerProfileManagementError: Error, Equatable, Sendable {
  case invalidName
  case invalidServerAddress
  case invalidCredentials
  case cannotModifyDefaultServer
}

public struct WebDAVServerProfileManagementUseCase: Sendable {
  private let repository: any WebDAVServerProfileRepository
  private let vault: any WebDAVServerCredentialVault
  private let makeID: @Sendable () -> Int64

  public init(
    repository: any WebDAVServerProfileRepository,
    vault: any WebDAVServerCredentialVault,
    makeID: @escaping @Sendable () -> Int64 = {
      Int64(Date().timeIntervalSince1970 * 1_000)
    }
  ) {
    self.repository = repository
    self.vault = vault
    self.makeID = makeID
  }

  @discardableResult
  public func save(
    id: Int64? = nil,
    name: String,
    serverAddress: String,
    username: String,
    password: String,
    sortNumber: Int = 0
  ) async throws -> WebDAVServerProfile {
    if id == WebDAVServerProfile.androidDefaultID {
      throw WebDAVServerProfileManagementError.cannotModifyDefaultServer
    }
    let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedName.isEmpty else {
      throw WebDAVServerProfileManagementError.invalidName
    }
    let normalizedAddress = serverAddress
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      let url = URL(string: normalizedAddress),
      let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      url.host != nil
    else {
      throw WebDAVServerProfileManagementError.invalidServerAddress
    }
    guard !username.isEmpty, !password.isEmpty else {
      throw WebDAVServerProfileManagementError.invalidCredentials
    }

    let profileID = id ?? makeID()
    let reference = Self.credentialReference(id: profileID)
    let oldCredential = await vault.credential(for: reference)
    let profile = WebDAVServerProfile(
      id: profileID,
      name: normalizedName,
      serverAddress: normalizedAddress,
      sortNumber: sortNumber,
      credentialReference: reference
    )
    do {
      try await vault.save(
        WebDAVServerCredential(username: username, password: password),
        for: reference
      )
      try await repository.upsertWebDAVServerProfile(profile)
      return profile
    } catch {
      if let oldCredential {
        try? await vault.save(oldCredential, for: reference)
      } else {
        await vault.remove(reference: reference)
      }
      throw error
    }
  }

  @discardableResult
  public func delete(id: Int64) async throws -> Int64? {
    guard id != WebDAVServerProfile.androidDefaultID else {
      throw WebDAVServerProfileManagementError.cannotModifyDefaultServer
    }
    let profiles = try await repository.webDAVServerProfiles()
    guard let profile = profiles.first(where: { $0.id == id }) else {
      return try await repository.selectedWebDAVServerProfileID()
    }
    try await repository.deleteWebDAVServerProfile(id: id)
    await vault.remove(reference: profile.credentialReference)

    let selectedID = try await repository.selectedWebDAVServerProfileID()
    guard selectedID == id else { return selectedID }
    let remaining = try await repository.webDAVServerProfiles()
    let fallback = remaining.first(where: \.isAndroidDefault)?.id
      ?? remaining.first?.id
    try await repository.selectWebDAVServerProfile(id: fallback)
    return fallback
  }

  public func select(id: Int64) async throws {
    let profiles = try await repository.webDAVServerProfiles()
    guard profiles.contains(where: { $0.id == id }) else { return }
    try await repository.selectWebDAVServerProfile(id: id)
  }

  public static func credentialReference(
    id: Int64
  ) -> WebDAVCredentialReference {
    WebDAVCredentialReference("webdav.server.\(id)")
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
