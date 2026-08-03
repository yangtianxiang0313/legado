import Foundation

public struct WebDAVBackupFile: Sendable, Equatable, Hashable {
  public let name: String
  public let size: Int64
  public let lastModifiedMilliseconds: Int64

  public init(
    name: String,
    size: Int64,
    lastModifiedMilliseconds: Int64
  ) {
    self.name = name
    self.size = max(0, size)
    self.lastModifiedMilliseconds = max(0, lastModifiedMilliseconds)
  }
}

public enum WebDAVBackupTransferFailure: Sendable, Equatable {
  case invalidConfiguration
  case invalidFileName
  case credentialUnavailable
  case authenticationRejected
  case notFound
  case remoteRejected(statusCode: Int)
  case invalidResponse
  case transportUnavailable
}

public enum WebDAVBackupListResult: Sendable, Equatable {
  case loaded([WebDAVBackupFile])
  case failed(WebDAVBackupTransferFailure)
}

public enum WebDAVBackupUploadResult: Sendable, Equatable {
  case uploaded
  case failed(WebDAVBackupTransferFailure)
}

public enum WebDAVBackupDownloadResult: Sendable, Equatable {
  case downloaded(Data)
  case failed(WebDAVBackupTransferFailure)
}

public protocol WebDAVBackupTransferring: Sendable {
  func listBackups(
    configuration: WebDAVConnectionConfiguration
  ) async -> WebDAVBackupListResult

  func uploadBackup(
    configuration: WebDAVConnectionConfiguration,
    fileName: String,
    data: Data
  ) async -> WebDAVBackupUploadResult

  func downloadBackup(
    configuration: WebDAVConnectionConfiguration,
    fileName: String
  ) async -> WebDAVBackupDownloadResult
}

public enum AndroidWebDAVBackupPath {
  public static func fileURL(
    configuration: WebDAVConnectionConfiguration,
    fileName: String
  ) -> URL? {
    guard isValidFileName(fileName), let rootURL = configuration.rootURL else {
      return nil
    }
    return rootURL.appendingPathComponent(fileName, isDirectory: false)
  }

  public static func isValidFileName(_ fileName: String) -> Bool {
    let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed == fileName
      && trimmed.hasPrefix("backup")
      && !trimmed.isEmpty
      && trimmed != "."
      && trimmed != ".."
      && !trimmed.contains("/")
      && !trimmed.contains("\\")
  }
}
