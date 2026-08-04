import AndroidBackupInterop
import ArchiveZIPFoundation
import Foundation
import LegadoCore
import ReaderCore

public enum AndroidReaderConfigArchiveExportError: Error, Equatable, Sendable {
  case archiveTooLarge
  case conflictingResourceName(String)
}

public struct AndroidReaderConfigArchiveExportFile: Equatable, Sendable {
  public let filename: String
  public let data: Data

  public init(filename: String, data: Data) {
    self.filename = filename
    self.data = data
  }
}

public enum AndroidReaderConfigArchiveExport {
  public static func configuration(
    name: String,
    preferences: ReaderPreferences
  ) throws -> AndroidReaderConfigDTO {
    let base = try AndroidReaderConfigDTO(jsonValue: .object([
      "name": .string(name),
    ]))
    return AndroidReaderConfigBundle(styles: [], sharedStyle: base)
      .applying(preferences).sharedStyle ?? base
  }

  public static func encode(
    _ configuration: AndroidReaderConfigDTO,
    maximumTotalBytes: UInt64 = 32 * 1_024 * 1_024
  ) throws -> AndroidReaderConfigArchiveExportFile {
    try encode(
      configuration,
      maximumTotalBytes: maximumTotalBytes,
      resourceLoader: { path in
        guard let url = fileURL(path),
          FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard UInt64(values.fileSize ?? 0) <= maximumTotalBytes else {
          throw AndroidReaderConfigArchiveExportError.archiveTooLarge
        }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
      }
    )
  }

  public static func encode(
    _ configuration: AndroidReaderConfigDTO,
    maximumTotalBytes: UInt64 = 32 * 1_024 * 1_024,
    resourceLoader: (String) throws -> Data?
  ) throws -> AndroidReaderConfigArchiveExportFile {
    let configurationData = try AndroidReaderConfigCodec.encodeShared(
      configuration
    )
    var resources: [String: Data] = [:]
    for path in resourcePaths(configuration) {
      guard let data = try resourceLoader(path) else { continue }
      let name = resourceName(path)
      guard !name.isEmpty else { continue }
      if let existing = resources[name], existing != data {
        throw AndroidReaderConfigArchiveExportError
          .conflictingResourceName(name)
      }
      resources[name] = data
    }
    let totalBytes = resources.values.reduce(
      UInt64(configurationData.count)
    ) { $0 + UInt64($1.count) }
    guard totalBytes <= maximumTotalBytes else {
      throw AndroidReaderConfigArchiveExportError.archiveTooLarge
    }
    let archiveURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString + ".zip")
    defer { try? FileManager.default.removeItem(at: archiveURL) }
    let members = [ArchiveZIPFoundation.Member(
      path: "readConfig.json",
      data: configurationData
    )] + resources.sorted(by: { $0.key < $1.key }).map {
      ArchiveZIPFoundation.Member(path: $0.key, data: $0.value)
    }
    try ArchiveZIPFoundation.create(members: members, at: archiveURL)
    return AndroidReaderConfigArchiveExportFile(
      filename: suggestedFilename(for: configuration),
      data: try Data(contentsOf: archiveURL, options: [.mappedIfSafe])
    )
  }

  private static func resourcePaths(
    _ configuration: AndroidReaderConfigDTO
  ) -> [String] {
    var values: [String] = []
    if let font = string(configuration, "textFont"), !font.isEmpty {
      values.append(font)
    }
    for (typeKey, pathKey) in [
      ("bgType", "bgStr"),
      ("bgTypeNight", "bgStrNight"),
      ("bgTypeEInk", "bgStrEInk"),
    ] where configuration.integer(typeKey) == 2 {
      if let path = string(configuration, pathKey), !path.isEmpty {
        values.append(path)
      }
    }
    return values
  }

  public static func suggestedFilename(
    for configuration: AndroidReaderConfigDTO
  ) -> String {
    guard let rawName = string(configuration, "name")?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !rawName.isEmpty
    else { return "readConfig.zip" }
    let invalid = CharacterSet(charactersIn: "/\\:")
      .union(.newlines)
      .union(.controlCharacters)
    let safe = rawName.unicodeScalars.map {
      invalid.contains($0) ? "_" : String($0)
    }.joined()
    return safe + ".zip"
  }

  private static func string(
    _ configuration: AndroidReaderConfigDTO,
    _ key: String
  ) -> String? {
    guard case .string(let value) = configuration.rawFields[key] else {
      return nil
    }
    return value
  }

  private static func fileURL(_ path: String) -> URL? {
    if let value = URL(string: path), value.isFileURL { return value }
    guard !path.contains("://") else { return nil }
    return URL(fileURLWithPath: path)
  }

  private static func resourceName(_ path: String) -> String {
    if let value = URL(string: path), value.isFileURL {
      return value.lastPathComponent
    }
    return URL(fileURLWithPath: path).lastPathComponent
  }
}

public enum AndroidReaderConfigAssetMaterializer {
  public static func materialize(
    _ payload: AndroidReaderConfigArchivePayload,
    rootURL: URL
  ) throws -> AndroidReaderConfigDTO {
    let safeName = payload.name.unicodeScalars.map {
      CharacterSet.alphanumerics.contains($0) ? Character(String($0)) : "_"
    }
    let directory = rootURL.appendingPathComponent(
      String(safeName),
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    var fields = payload.configuration.rawFields
    var pathKeys = ["textFont"]
    for (typeKey, pathKey) in [
      ("bgType", "bgStr"),
      ("bgTypeNight", "bgStrNight"),
      ("bgTypeEInk", "bgStrEInk"),
    ] where payload.configuration.integer(typeKey) == 2 {
      pathKeys.append(pathKey)
    }
    for key in pathKeys {
      guard case .string(let rawPath) = fields[key], !rawPath.isEmpty else {
        continue
      }
      let fileName = URL(fileURLWithPath: rawPath).lastPathComponent
      guard let resource = payload.resources.first(where: {
        URL(fileURLWithPath: $0.key).lastPathComponent == fileName
      }) else { continue }
      let destination = directory.appendingPathComponent(fileName)
      try resource.value.write(to: destination, options: .atomic)
      fields[key] = .string(destination.path)
    }
    return try AndroidReaderConfigDTO(jsonValue: .object(fields))
  }
}
