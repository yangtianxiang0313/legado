import AppUseCases
import Foundation
import IntegrationKit
import ReaderCore

public protocol AndroidCoreBackupExporting: Sendable {
  func export(
    to archiveURL: URL,
    bookSources: [BookSourceDraft],
    replacementRules: [ReaderReplacementRule],
    readerPreferences: ReaderPreferences?
  ) async throws -> AndroidLibraryBackupSummary
}

extension AndroidLibraryBackupUseCase: AndroidCoreBackupExporting {}

public protocol AndroidCoreBackupRestoring: Sendable {
  func restore(from archiveURL: URL) async throws
    -> AndroidCoreBackupRestoreSummary
}

extension AndroidCoreBackupRestoreUseCase: AndroidCoreBackupRestoring {}

public enum WebDAVBackupSyncFailure: Sendable, Equatable {
  case localArchiveCreation
  case export
  case localArchiveRead
  case localArchiveWrite
  case upload(WebDAVBackupTransferFailure)
  case download(WebDAVBackupTransferFailure)
  case restore
}

public enum WebDAVBackupSyncUploadResult: Sendable, Equatable {
  case uploaded(fileName: String, summary: AndroidLibraryBackupSummary)
  case failed(WebDAVBackupSyncFailure)
}

public enum WebDAVBackupSyncRestoreResult: Sendable, Equatable {
  case restored(AndroidCoreBackupRestoreSummary)
  case failed(WebDAVBackupSyncFailure)
}

public struct WebDAVBackupSyncUseCase: Sendable {
  private let transfer: any WebDAVBackupTransferring
  private let exporter: any AndroidCoreBackupExporting
  private let restorer: any AndroidCoreBackupRestoring

  public init(
    transfer: any WebDAVBackupTransferring,
    exporter: any AndroidCoreBackupExporting,
    restorer: any AndroidCoreBackupRestoring
  ) {
    self.transfer = transfer
    self.exporter = exporter
    self.restorer = restorer
  }

  public func listBackups(
    configuration: WebDAVConnectionConfiguration
  ) async -> WebDAVBackupListResult {
    await transfer.listBackups(configuration: configuration)
  }

  public func upload(
    configuration: WebDAVConnectionConfiguration,
    fileName: String,
    bookSources: [BookSourceDraft],
    replacementRules: [ReaderReplacementRule],
    readerPreferences: ReaderPreferences? = nil
  ) async -> WebDAVBackupSyncUploadResult {
    let temporary = temporaryArchiveURL()
    do {
      try FileManager.default.createDirectory(
        at: temporary.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
    } catch {
      return .failed(.localArchiveCreation)
    }
    defer {
      try? FileManager.default.removeItem(
        at: temporary.deletingLastPathComponent()
      )
    }

    let summary: AndroidLibraryBackupSummary
    do {
      summary = try await exporter.export(
        to: temporary,
        bookSources: bookSources,
        replacementRules: replacementRules,
        readerPreferences: readerPreferences
      )
    } catch {
      return .failed(.export)
    }

    let data: Data
    do {
      data = try Data(contentsOf: temporary)
    } catch {
      return .failed(.localArchiveRead)
    }
    switch await transfer.uploadBackup(
      configuration: configuration,
      fileName: fileName,
      data: data
    ) {
    case .uploaded:
      return .uploaded(fileName: fileName, summary: summary)
    case .failed(let failure):
      return .failed(.upload(failure))
    }
  }

  public func restore(
    configuration: WebDAVConnectionConfiguration,
    fileName: String
  ) async -> WebDAVBackupSyncRestoreResult {
    let data: Data
    switch await transfer.downloadBackup(
      configuration: configuration,
      fileName: fileName
    ) {
    case .downloaded(let value):
      data = value
    case .failed(let failure):
      return .failed(.download(failure))
    }

    let temporary = temporaryArchiveURL()
    do {
      try FileManager.default.createDirectory(
        at: temporary.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try data.write(to: temporary, options: .atomic)
    } catch {
      try? FileManager.default.removeItem(
        at: temporary.deletingLastPathComponent()
      )
      return .failed(.localArchiveWrite)
    }
    defer {
      try? FileManager.default.removeItem(
        at: temporary.deletingLastPathComponent()
      )
    }

    do {
      return .restored(try await restorer.restore(from: temporary))
    } catch {
      return .failed(.restore)
    }
  }

  public static func androidFileName(
    date: Date,
    deviceName: String? = nil,
    timeZone: TimeZone = .current
  ) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    let suffix = deviceName?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if let suffix, !suffix.isEmpty {
      return "backup\(formatter.string(from: date))-\(suffix).zip"
    }
    return "backup\(formatter.string(from: date)).zip"
  }

  private func temporaryArchiveURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
      .appendingPathComponent("backup.zip", isDirectory: false)
  }
}
