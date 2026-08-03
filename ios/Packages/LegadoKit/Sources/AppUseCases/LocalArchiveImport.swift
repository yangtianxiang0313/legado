import Foundation
import LibraryDomain

public enum LocalArchiveBookFormat: String, Equatable, Sendable {
  case text = "txt"
  case epub
}

public struct LocalArchiveMember: Equatable, Sendable {
  public let path: String
  public let byteCount: Int

  public init(path: String, byteCount: Int) {
    self.path = path
    self.byteCount = byteCount
  }

  public var fileName: String {
    path.split(separator: "/").last.map(String.init) ?? path
  }
}

public struct LocalArchiveImportEntry: Equatable, Sendable {
  public let path: String
  public let fileName: String
  public let format: LocalArchiveBookFormat

  public init(path: String, fileName: String, format: LocalArchiveBookFormat) {
    self.path = path
    self.fileName = fileName
    self.format = format
  }
}

public enum LocalArchiveSkipReason: String, Equatable, Sendable {
  case unsupportedBookFormat = "unsupported_book_format"
  case unrelatedFile = "unrelated_file"
}

public struct LocalArchiveSkippedEntry: Equatable, Sendable {
  public let path: String
  public let reason: LocalArchiveSkipReason

  public init(path: String, reason: LocalArchiveSkipReason) {
    self.path = path
    self.reason = reason
  }
}

public struct LocalArchiveImportPlan: Equatable, Sendable {
  public let entries: [LocalArchiveImportEntry]
  public let skipped: [LocalArchiveSkippedEntry]

  public init(
    entries: [LocalArchiveImportEntry],
    skipped: [LocalArchiveSkippedEntry]
  ) {
    self.entries = entries
    self.skipped = skipped
  }
}

public enum LocalArchiveImportFailure: Error, Equatable, Sendable {
  case noSupportedBookEntry
}

public enum LocalArchiveImportPlanner {
  /// Android filters archive members with `bookFileRegex` before importing.
  /// iOS preserves that distinction while explicitly deferring formats whose
  /// parsers have not yet migrated instead of silently claiming parity.
  public static func plan(
    members: [LocalArchiveMember]
  ) throws -> LocalArchiveImportPlan {
    var entries: [LocalArchiveImportEntry] = []
    var skipped: [LocalArchiveSkippedEntry] = []
    for member in members {
      let fileExtension = extensionOf(member.fileName)
      if let format = LocalArchiveBookFormat(rawValue: fileExtension) {
        entries.append(
          LocalArchiveImportEntry(
            path: member.path,
            fileName: member.fileName,
            format: format
          )
        )
      } else {
        skipped.append(
          LocalArchiveSkippedEntry(
            path: member.path,
            reason: ["umd", "pdf"].contains(fileExtension)
              ? .unsupportedBookFormat
              : .unrelatedFile
          )
        )
      }
    }
    guard !entries.isEmpty else {
      throw LocalArchiveImportFailure.noSupportedBookEntry
    }
    return LocalArchiveImportPlan(entries: entries, skipped: skipped)
  }

  private static func extensionOf(_ fileName: String) -> String {
    guard let dot = fileName.lastIndex(of: ".") else { return "" }
    return String(fileName[fileName.index(after: dot)...]).lowercased()
  }
}

public enum AndroidLocalArchiveBookOrigin {
  public static let prefix = "loc_book::"

  public static func encode(archiveName: String) -> String {
    prefix + archiveName
  }

  public static func decode(_ sourceID: String) -> String? {
    guard sourceID.hasPrefix(prefix) else { return nil }
    let name = String(sourceID.dropFirst(prefix.count))
    return name.isEmpty ? nil : name
  }
}

public struct LocalArchiveImportedBook: Equatable, Sendable {
  public let entryPath: String
  public let bookID: BookID
  public let bookName: String

  public init(entryPath: String, bookID: BookID, bookName: String) {
    self.entryPath = entryPath
    self.bookID = bookID
    self.bookName = bookName
  }
}

public struct LocalArchiveImportItem: Sendable {
  public let entry: LocalArchiveImportEntry
  public let managedReference: String
  public let payload: LocalBookPayload

  public init(
    entry: LocalArchiveImportEntry,
    managedReference: String,
    payload: LocalBookPayload
  ) {
    self.entry = entry
    self.managedReference = managedReference
    self.payload = payload
  }
}

public struct LocalArchiveEntryFailure: Equatable, Sendable {
  public let entryPath: String
  public let message: String

  public init(entryPath: String, message: String) {
    self.entryPath = entryPath
    self.message = message
  }
}

public struct LocalArchiveImportReport: Equatable, Sendable {
  public let archiveName: String
  public let imported: [LocalArchiveImportedBook]
  public let failures: [LocalArchiveEntryFailure]
  public let skipped: [LocalArchiveSkippedEntry]

  public init(
    archiveName: String,
    imported: [LocalArchiveImportedBook],
    failures: [LocalArchiveEntryFailure],
    skipped: [LocalArchiveSkippedEntry]
  ) {
    self.archiveName = archiveName
    self.imported = imported
    self.failures = failures
    self.skipped = skipped
  }
}
