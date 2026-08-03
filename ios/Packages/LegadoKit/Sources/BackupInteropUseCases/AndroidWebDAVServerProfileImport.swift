import AndroidBackupInterop
import Foundation
import LegadoCore

public struct AndroidWebDAVServerProfile: Equatable, Sendable {
  public let id: Int64
  public let name: String
  public let url: String
  public let username: String
  public let password: String
  public let sortNumber: Int

  public init(
    id: Int64,
    name: String,
    url: String,
    username: String,
    password: String,
    sortNumber: Int
  ) {
    self.id = id
    self.name = name
    self.url = url
    self.username = username
    self.password = password
    self.sortNumber = sortNumber
  }
}

public enum AndroidServerProfileImportEntry: Equatable, Sendable {
  case webDAV(AndroidWebDAVServerProfile)
  case unsupported(id: Int64, name: String, type: String)
  case invalidWebDAVConfiguration(id: Int64, name: String)
}

public struct AndroidServerProfileImportPlan: Equatable, Sendable {
  public let entries: [AndroidServerProfileImportEntry]

  public init(entries: [AndroidServerProfileImportEntry]) {
    self.entries = entries
  }

  public var webDAVProfiles: [AndroidWebDAVServerProfile] {
    entries.compactMap {
      guard case .webDAV(let profile) = $0 else { return nil }
      return profile
    }
  }
}

public enum AndroidServerProfileImportAdapter {
  public static func plan(
    from archiveURL: URL,
    backupPassword: String?
  ) throws -> AndroidServerProfileImportPlan {
    let values = try AndroidBackupArchive.readServerProfiles(
      from: archiveURL,
      backupPassword: backupPassword
    )
    return AndroidServerProfileImportPlan(entries: values.map(project))
  }

  private static func project(
    _ value: AndroidServerProfileDTO
  ) -> AndroidServerProfileImportEntry {
    guard value.type == "WEBDAV" else {
      return .unsupported(id: value.id, name: value.name, type: value.type)
    }
    guard
      let config = value.config,
      let data = config.data(using: .utf8),
      let decoded = try? JSONValueCodec.decode(data),
      case .object(let object) = decoded,
      case .string(let url)? = object["url"],
      case .string(let username)? = object["username"],
      case .string(let password)? = object["password"]
    else {
      return .invalidWebDAVConfiguration(id: value.id, name: value.name)
    }
    return .webDAV(
      AndroidWebDAVServerProfile(
        id: value.id,
        name: value.name,
        url: url,
        username: username,
        password: password,
        sortNumber: value.sortNumber
      )
    )
  }
}
