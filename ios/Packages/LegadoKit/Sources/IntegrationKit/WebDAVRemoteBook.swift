import Foundation

public struct WebDAVRemoteBookResource: Sendable, Equatable, Hashable {
  public let name: String
  public let url: URL
  public let size: Int64
  public let lastModifiedMilliseconds: Int64
  public let isDirectory: Bool

  public init(
    name: String,
    url: URL,
    size: Int64,
    lastModifiedMilliseconds: Int64,
    isDirectory: Bool
  ) {
    self.name = name
    self.url = url
    self.size = max(0, size)
    self.lastModifiedMilliseconds = max(0, lastModifiedMilliseconds)
    self.isDirectory = isDirectory
  }
}

public enum AndroidRemoteBookFilePolicy {
  private static let supportedExtensions: Set<String> = [
    "txt", "epub", "umd", "pdf", "zip", "rar", "7z",
  ]

  public static func includes(name: String, isDirectory: Bool) -> Bool {
    if isDirectory { return true }
    let pathExtension = (name as NSString).pathExtension.lowercased()
    return supportedExtensions.contains(pathExtension)
  }
}

public enum WebDAVRemoteBookFailure: Sendable, Equatable {
  case invalidConfiguration
  case invalidResourceURL
  case invalidFileName
  case credentialUnavailable
  case authenticationRejected
  case notFound
  case remoteRejected(statusCode: Int)
  case invalidResponse
  case transportUnavailable
}

public enum WebDAVRemoteBookListResult: Sendable, Equatable {
  case loaded([WebDAVRemoteBookResource])
  case failed(WebDAVRemoteBookFailure)
}

public enum WebDAVRemoteBookDownloadResult: Sendable, Equatable {
  case downloaded(name: String, data: Data)
  case failed(WebDAVRemoteBookFailure)
}

public enum WebDAVRemoteBookUploadResult: Sendable, Equatable {
  case uploaded(name: String, remoteURL: URL)
  case failed(WebDAVRemoteBookFailure)
}

public protocol WebDAVRemoteBookTransferring: Sendable {
  func listRemoteBooks(
    configuration: WebDAVConnectionConfiguration,
    directoryURL: URL?
  ) async -> WebDAVRemoteBookListResult

  func downloadRemoteBook(
    configuration: WebDAVConnectionConfiguration,
    resource: WebDAVRemoteBookResource
  ) async -> WebDAVRemoteBookDownloadResult

  func uploadRemoteBook(
    configuration: WebDAVConnectionConfiguration,
    fileName: String,
    data: Data
  ) async -> WebDAVRemoteBookUploadResult
}

public extension WebDAVRemoteBookTransferring {
  func uploadRemoteBook(
    configuration: WebDAVConnectionConfiguration,
    fileName: String,
    data: Data
  ) async -> WebDAVRemoteBookUploadResult {
    .failed(.transportUnavailable)
  }
}
