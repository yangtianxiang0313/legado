import ArchiveZIPFoundation
import Foundation

public enum AndroidBackupMemberDisposition: String, Sendable, Equatable {
  case supported
  case deferred
  case unsafe
  case malformed
}

public struct AndroidBackupMemberInspection: Sendable, Equatable {
  public let path: String
  public let uncompressedSize: UInt64
  public let disposition: AndroidBackupMemberDisposition
  public let reason: String

  public init(
    path: String,
    uncompressedSize: UInt64,
    disposition: AndroidBackupMemberDisposition,
    reason: String
  ) {
    self.path = path
    self.uncompressedSize = uncompressedSize
    self.disposition = disposition
    self.reason = reason
  }
}

public struct AndroidBackupPreflightReport: Sendable, Equatable {
  public let members: [AndroidBackupMemberInspection]

  public init(members: [AndroidBackupMemberInspection]) {
    self.members = members
  }

  public var hasBlockingIssues: Bool {
    members.contains {
      $0.disposition == .unsafe || $0.disposition == .malformed
    }
  }
}

public extension AndroidBackupArchive {
  static let deferredMemberNames: Set<String> = [
    "directLinkUploadRule.json"
  ]

  static let supportedMemberNames: Set<String> = [
    bookSourcesMember,
    replacementRulesMember,
    booksMember,
    bookGroupsMember,
    bookmarksMember,
    readRecordsMember,
    searchHistoryMember,
    ruleSubscriptionsMember,
    rssSourcesMember,
    rssStarsMember,
    httpTextToSpeechMember,
    localTextTOCRulesMember,
    readerConfigsMember,
    sharedReaderConfigMember,
    dictionaryRulesMember,
    keyboardAssistsMember,
    themeConfigsMember,
    sharedPreferencesMember,
    serverProfilesMember,
  ]

  static var knownAndroidMemberNames: Set<String> {
    supportedMemberNames.union(deferredMemberNames)
  }

  static func preflight(from archiveURL: URL) -> AndroidBackupPreflightReport {
    let descriptors: [ArchiveZIPFoundation.Descriptor]
    do {
      descriptors = try ArchiveZIPFoundation.descriptors(at: archiveURL)
    } catch let error as ArchiveZIPFoundation.ContainerError {
      return AndroidBackupPreflightReport(
        members: [containerFailure(error)]
      )
    } catch {
      return AndroidBackupPreflightReport(
        members: [
          AndroidBackupMemberInspection(
            path: "<archive>",
            uncompressedSize: 0,
            disposition: .malformed,
            reason: "archive_unreadable"
          )
        ]
      )
    }

    return AndroidBackupPreflightReport(
      members: descriptors.map { descriptor in
        inspect(descriptor, archiveURL: archiveURL)
      }
    )
  }

  private static func inspect(
    _ descriptor: ArchiveZIPFoundation.Descriptor,
    archiveURL: URL
  ) -> AndroidBackupMemberInspection {
    let path = descriptor.path
    guard knownAndroidMemberNames.contains(path) else {
      return AndroidBackupMemberInspection(
        path: path,
        uncompressedSize: descriptor.uncompressedSize,
        disposition: .unsafe,
        reason: "unknown_android_backup_member"
      )
    }
    let maximumBytes = maximumBytes(for: path)
    guard descriptor.uncompressedSize <= maximumBytes else {
      return AndroidBackupMemberInspection(
        path: path,
        uncompressedSize: descriptor.uncompressedSize,
        disposition: .malformed,
        reason: "member_too_large"
      )
    }
    do {
      guard let data = try ArchiveZIPFoundation.read(
        path,
        from: archiveURL,
        maximumBytes: maximumBytes
      ) else {
        return malformed(path, size: descriptor.uncompressedSize, "member_missing")
      }
      try validateSyntax(data, path: path)
    } catch {
      return malformed(path, size: descriptor.uncompressedSize, "invalid_payload")
    }
    return AndroidBackupMemberInspection(
      path: path,
      uncompressedSize: descriptor.uncompressedSize,
      disposition: deferredMemberNames.contains(path) ? .deferred : .supported,
      reason: deferredMemberNames.contains(path)
        ? "known_android_domain_not_mapped"
        : "mapped_android_domain"
    )
  }

  private static func validateSyntax(_ data: Data, path: String) throws {
    if path == sharedPreferencesMember {
      _ = try AndroidSharedPreferencesCodec.decode(data)
      return
    }
    if path == serverProfilesMember {
      let first = data.first { byte in
        byte != 0x20 && byte != 0x09 && byte != 0x0a && byte != 0x0d
      }
      if first != UInt8(ascii: "[") && first != UInt8(ascii: "{") {
        // Android encrypts the complete JSON text as Base64 when a backup
        // password is configured. Password validation remains in restore().
        guard !data.isEmpty else { throw PreflightSyntaxError.invalidJSON }
        return
      }
    }
    let object = try JSONSerialization.jsonObject(with: data)
    let expectsObject = path == sharedReaderConfigMember
      || path == "directLinkUploadRule.json"
    if expectsObject {
      guard object is [String: Any] else {
        throw PreflightSyntaxError.invalidJSON
      }
    } else {
      guard object is [Any] else {
        throw PreflightSyntaxError.invalidJSON
      }
    }
  }

  private static func maximumBytes(for path: String) -> UInt64 {
    if path == sharedPreferencesMember || path == serverProfilesMember {
      return 4 * 1_024 * 1_024
    }
    if path == booksMember || path == rssSourcesMember || path == rssStarsMember {
      return 64 * 1_024 * 1_024
    }
    return 32 * 1_024 * 1_024
  }

  private static func malformed(
    _ path: String,
    size: UInt64,
    _ reason: String
  ) -> AndroidBackupMemberInspection {
    AndroidBackupMemberInspection(
      path: path,
      uncompressedSize: size,
      disposition: .malformed,
      reason: reason
    )
  }

  private static func containerFailure(
    _ error: ArchiveZIPFoundation.ContainerError
  ) -> AndroidBackupMemberInspection {
    let path: String
    let reason: String
    switch error {
    case .invalidMemberPath(let value):
      path = value
      reason = "invalid_member_path"
    case .duplicateMemberPath(let value):
      path = value
      reason = "duplicate_member_path"
    case .memberTooLarge(let value):
      path = value
      reason = "member_too_large"
    case .nonFileMember(let value):
      path = value
      reason = "non_file_member"
    }
    return malformed(path, size: 0, reason)
  }
}

private enum PreflightSyntaxError: Error {
  case invalidJSON
}
