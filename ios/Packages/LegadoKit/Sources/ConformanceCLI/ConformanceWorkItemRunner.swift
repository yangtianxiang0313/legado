import Foundation
import LegadoCore
import SourceRuntime

public enum ConformanceWorkItemError: String, Error, Equatable, Sendable {
  case invalidWorkItemID = "invalid_work_item_id"
  case invalidRepositoryRoot = "invalid_repository_root"
  case invalidWorkItem = "invalid_work_item"
  case invalidFixtureManifest = "invalid_fixture_manifest"
  case fixtureNotIndexed = "fixture_not_indexed"
  case fixtureDigestMismatch = "fixture_digest_mismatch"
  case fixtureIdentityMismatch = "fixture_identity_mismatch"
  case pathEscapesRepository = "path_escapes_repository"
}

public enum ConformanceWorkItemRunner {
  public static func run(
    workItemID: String,
    repositoryRoot: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
  ) async throws -> Data {
    guard
      workItemID.range(
        of: #"^IOS-[A-Z][A-Z0-9-]*-[0-9]{3}$"#,
        options: .regularExpression
      ) != nil
    else {
      throw ConformanceWorkItemError.invalidWorkItemID
    }
    let root = repositoryRoot.standardizedFileURL.resolvingSymlinksInPath()
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
      throw ConformanceWorkItemError.invalidRepositoryRoot
    }
    let itemURL = try resolve(
      "ios/harness/work-items/\(workItemID).json",
      repositoryRoot: root
    )
    let item = try decodeJSON(at: itemURL, mappedError: .invalidWorkItem)
    let fixtureIDs = try selectedFixtureIDs(item)
    let manifestURL = try resolve("ios/harness/fixtures/manifest.json", repositoryRoot: root)
    let manifest = try decodeJSON(at: manifestURL, mappedError: .invalidFixtureManifest)
    let indexed = try fixtureIndex(manifest)
    var artifacts: [JSONValue] = []
    artifacts.reserveCapacity(fixtureIDs.count)
    for fixtureID in fixtureIDs {
      guard let fixture = indexed[fixtureID] else {
        throw ConformanceWorkItemError.fixtureNotIndexed
      }
      let directory = try resolve(fixture.path, repositoryRoot: root)
      guard directory.lastPathComponent == fixtureID else {
        throw ConformanceWorkItemError.fixtureIdentityMismatch
      }
      guard try fixtureDigest(directory) == fixture.sha256 else {
        throw ConformanceWorkItemError.fixtureDigestMismatch
      }
      let data = try await ConformanceRunner.run(fixtureDirectory: directory)
      let artifact = try JSONValueCodec.decode(data)
      guard
        case .object(let artifactRoot) = artifact,
        artifactRoot["fixture_id"] == .string(fixtureID)
      else {
        throw ConformanceWorkItemError.fixtureIdentityMismatch
      }
      artifacts.append(artifact)
    }
    return try JSONValueCodec.encode(
      .object([
        "schema_version": .number(JSONNumber(1)),
        "work_item_id": .string(workItemID),
        "fixtures": .array(artifacts),
      ])
    )
  }

  private static func selectedFixtureIDs(_ item: JSONValue) throws -> [String] {
    guard
      case .object(let root) = item,
      case .object(let spec)? = root["spec"],
      case .object(let inputs)? = spec["inputs"],
      case .array(let fixtures)? = inputs["fixtures"]
    else {
      throw ConformanceWorkItemError.invalidWorkItem
    }
    var seen: Set<String> = []
    return try fixtures.map { value in
      guard case .string(let fixtureID) = value, !fixtureID.isEmpty, seen.insert(fixtureID).inserted else {
        throw ConformanceWorkItemError.invalidWorkItem
      }
      return fixtureID
    }
  }

  private static func fixtureIndex(_ manifest: JSONValue) throws -> [String: IndexedFixture] {
    guard
      case .object(let root) = manifest,
      case .number(let schemaVersion)? = root["schema_version"],
      schemaVersion.rawToken == "1",
      root["compatibility_profile"] == .string("android-legado-v1"),
      root["canonicalizer"] == .string("canonical-v1"),
      case .array(let fixtures)? = root["fixtures"]
    else {
      throw ConformanceWorkItemError.invalidFixtureManifest
    }
    var result: [String: IndexedFixture] = [:]
    var paths: Set<String> = []
    for value in fixtures {
      guard
        case .object(let entry) = value,
        case .string(let fixtureID)? = entry["id"],
        case .string(let path)? = entry["path"],
        case .string(let sha256)? = entry["sha256"],
        path.hasPrefix("ios/harness/fixtures/"),
        paths.insert(path).inserted,
        result.updateValue(
          IndexedFixture(path: path, sha256: sha256),
          forKey: fixtureID
        ) == nil
      else {
        throw ConformanceWorkItemError.invalidFixtureManifest
      }
    }
    return result
  }

  private static func fixtureDigest(_ directory: URL) throws -> String {
    let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
    var enumerationFailed = false
    guard
      let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: resourceKeys,
        errorHandler: { _, _ in
          enumerationFailed = true
          return false
        }
      )
    else {
      throw ConformanceWorkItemError.invalidFixtureManifest
    }
    var files: [URL] = []
    while let file = enumerator.nextObject() as? URL {
      let values: URLResourceValues
      do {
        values = try file.resourceValues(forKeys: Set(resourceKeys))
      } catch {
        throw ConformanceWorkItemError.invalidFixtureManifest
      }
      guard values.isSymbolicLink != true else {
        throw ConformanceWorkItemError.pathEscapesRepository
      }
      if values.isRegularFile == true {
        files.append(file.standardizedFileURL.resolvingSymlinksInPath())
      }
    }
    guard !enumerationFailed else {
      throw ConformanceWorkItemError.invalidFixtureManifest
    }
    let rootPath = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
    let inventory = try files.sorted { $0.path < $1.path }.map { file -> JSONValue in
      guard file.path.hasPrefix(rootPath) else {
        throw ConformanceWorkItemError.pathEscapesRepository
      }
      let data = try Data(contentsOf: file, options: [.mappedIfSafe])
      return .object([
        "path": .string(String(file.path.dropFirst(rootPath.count))),
        "sha256": .string(sha256(data)),
      ])
    }
    return try sha256(JSONValueCodec.encode(.array(inventory)))
  }

  private static func sha256(_ data: Data) -> String {
    HTTPBodyEnvelope(body: HTTPBody(data)).sha256
  }

  private static func decodeJSON(
    at url: URL,
    mappedError: ConformanceWorkItemError
  ) throws -> JSONValue {
    do {
      return try JSONValueCodec.decode(Data(contentsOf: url, options: [.mappedIfSafe]))
    } catch {
      throw mappedError
    }
  }

  private static func resolve(_ relativePath: String, repositoryRoot: URL) throws -> URL {
    let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
    guard
      !relativePath.isEmpty,
      !relativePath.hasPrefix("/"),
      !relativePath.contains("\\"),
      !relativePath.contains("\0"),
      components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else {
      throw ConformanceWorkItemError.pathEscapesRepository
    }
    let candidate =
      repositoryRoot
      .appendingPathComponent(relativePath)
      .standardizedFileURL
      .resolvingSymlinksInPath()
    let rootPath =
      repositoryRoot.path.hasSuffix("/") ? repositoryRoot.path : repositoryRoot.path + "/"
    guard candidate.path.hasPrefix(rootPath) else {
      throw ConformanceWorkItemError.pathEscapesRepository
    }
    return candidate
  }

  private struct IndexedFixture {
    let path: String
    let sha256: String
  }
}
