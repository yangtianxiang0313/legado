import AndroidBackupInterop
import ArchiveZIPFoundation
import Foundation
import LegadoCore
import ReaderCore
import Observation

public enum AndroidReaderConfigArchiveImportError: Error, Equatable {
  case missingConfiguration
  case tooManyMembers
  case archiveTooLarge
}

public struct AndroidReaderConfigArchivePayload: Equatable, Sendable {
  public let configuration: AndroidReaderConfigDTO
  public let resources: [String: Data]

  public init(
    configuration: AndroidReaderConfigDTO,
    resources: [String: Data]
  ) {
    self.configuration = configuration
    self.resources = resources
  }

  public var name: String {
    guard case .string(let value) = configuration.rawFields["name"] else {
      return "未命名阅读配置"
    }
    return value.isEmpty ? "未命名阅读配置" : value
  }

  public var projection: AndroidReaderConfigProjection? {
    AndroidReaderConfigBundle(styles: [], sharedStyle: configuration)
      .projection
  }
}

public enum AndroidReaderConfigArchiveImport {
  public static func decode(
    from archiveURL: URL,
    maximumMembers: Int = 16,
    maximumTotalBytes: UInt64 = 32 * 1_024 * 1_024
  ) throws -> AndroidReaderConfigArchivePayload {
    let descriptors = try ArchiveZIPFoundation.descriptors(at: archiveURL)
    guard descriptors.count <= maximumMembers else {
      throw AndroidReaderConfigArchiveImportError.tooManyMembers
    }
    guard descriptors.reduce(UInt64(0), { $0 + $1.uncompressedSize })
      <= maximumTotalBytes
    else { throw AndroidReaderConfigArchiveImportError.archiveTooLarge }
    guard descriptors.contains(where: { $0.path == "readConfig.json" }),
      let configData = try ArchiveZIPFoundation.read(
        "readConfig.json",
        from: archiveURL,
        maximumBytes: 2 * 1_024 * 1_024
      )
    else { throw AndroidReaderConfigArchiveImportError.missingConfiguration }
    let configuration = try AndroidReaderConfigCodec.decodeShared(configData)
    var resources: [String: Data] = [:]
    for descriptor in descriptors where descriptor.path != "readConfig.json" {
      if let data = try ArchiveZIPFoundation.read(
        descriptor.path,
        from: archiveURL,
        maximumBytes: maximumTotalBytes
      ) {
        resources[descriptor.path] = data
      }
    }
    return AndroidReaderConfigArchivePayload(
      configuration: configuration,
      resources: resources
    )
  }
}

public protocol AndroidReaderConfigProfileRepository: Sendable {
  func androidReaderConfigBundle() async throws -> AndroidReaderConfigBundle?
  func restoreAndroidReaderConfigBundle(
    _ bundle: AndroidReaderConfigBundle
  ) async throws
}

@MainActor
@Observable
public final class AndroidReaderConfigProfileStore {
  public private(set) var profiles: [AndroidReaderConfigDTO] = []
  public private(set) var errorMessage: String?
  private let repository: any AndroidReaderConfigProfileRepository

  public init(repository: any AndroidReaderConfigProfileRepository) {
    self.repository = repository
  }

  public func reload() async {
    do {
      profiles = try await repository.androidReaderConfigBundle()?.styles ?? []
      errorMessage = nil
    } catch { errorMessage = "无法读取阅读配置" }
  }

  @discardableResult
  public func importProfile(_ value: AndroidReaderConfigDTO) async -> Bool {
    do {
      let existing = try await repository.androidReaderConfigBundle()
      var styles = existing?.styles ?? []
      let name = Self.name(value)
      if let index = styles.firstIndex(where: { Self.name($0) == name }) {
        styles[index] = value
      } else {
        styles.append(value)
      }
      try await repository.restoreAndroidReaderConfigBundle(
        AndroidReaderConfigBundle(
          styles: styles,
          sharedStyle: existing?.sharedStyle
        )
      )
      await reload()
      return true
    } catch {
      errorMessage = "无法导入阅读配置"
      return false
    }
  }

  private static func name(_ value: AndroidReaderConfigDTO) -> String {
    guard case .string(let name) = value.rawFields["name"] else { return "" }
    return name
  }
}
