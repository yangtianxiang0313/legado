import Foundation
import LegadoCore
import SourceRuntime
import TestSupport

public enum ConformanceWorkItemError: String, Error, Equatable, Sendable {
  case invalidWorkItemID = "invalid_work_item_id"
  case invalidRepositoryRoot = "invalid_repository_root"
  case invalidWorkItem = "invalid_work_item"
  case invalidFixtureManifest = "invalid_fixture_manifest"
  case fixtureNotIndexed = "fixture_not_indexed"
  case fixtureDigestMismatch = "fixture_digest_mismatch"
  case fixtureIdentityMismatch = "fixture_identity_mismatch"
  case invalidGoldenManifest = "invalid_golden_manifest"
  case goldenNotIndexed = "golden_not_indexed"
  case goldenDigestMismatch = "golden_digest_mismatch"
  case goldenIdentityMismatch = "golden_identity_mismatch"
  case goldenProjectionMissing = "golden_projection_missing"
  case pathEscapesRepository = "path_escapes_repository"
}

public struct GoldenProjectionMismatch: Error, Equatable, Sendable, CustomStringConvertible {
  public let fixtureID: String
  public let difference: CanonicalDifference

  public init(fixtureID: String, difference: CanonicalDifference) {
    self.fixtureID = fixtureID
    self.difference = difference
  }

  public var description: String {
    "golden_projection_mismatch:\(fixtureID):\(difference.kind.rawValue):\(difference.jsonPointer)"
  }
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
      let loaded = try FixtureLoader.loadForConformance(from: directory)
      let data: Data
      switch loaded {
      case .transport(let loadedFixture)
        where loadedFixture.definition.operation == .sourceLabSite:
        data = try await SourcePipelineConformanceRunner.run(loadedFixture)
      default:
        data = try await ConformanceRunner.run(fixtureDirectory: directory)
      }
      var artifact = try JSONValueCodec.decode(data)
      guard
        case .object(let artifactRoot) = artifact,
        artifactRoot["fixture_id"] == .string(fixtureID)
      else {
        throw ConformanceWorkItemError.fixtureIdentityMismatch
      }
      if case .transport(let loadedFixture) = loaded,
        loadedFixture.definition.operation == .sourceLabSite
      {
        artifact = try compareWithAndroidGolden(
          artifact,
          fixtureID: fixtureID,
          fixtureSHA256: fixture.sha256,
          repositoryRoot: root
        )
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

  private static func compareWithAndroidGolden(
    _ artifact: JSONValue,
    fixtureID: String,
    fixtureSHA256: String,
    repositoryRoot: URL
  ) throws -> JSONValue {
    let manifestURL = try resolve(
      "ios/harness/goldens/manifest.json",
      repositoryRoot: repositoryRoot
    )
    let manifest = try decodeJSON(at: manifestURL, mappedError: .invalidGoldenManifest)
    guard
      case .object(let manifestRoot) = manifest,
      manifestRoot["schema_version"] == .number(JSONNumber(1)),
      case .object(let oracle)? = manifestRoot["oracle"],
      oracle["profile"] == .string("android-legado-v1"),
      case .object(let fixtures)? = manifestRoot["fixtures"]
    else {
      throw ConformanceWorkItemError.invalidGoldenManifest
    }
    guard
      case .object(let entry)? = fixtures[fixtureID],
      case .string(let path)? = entry["path"],
      case .string(let goldenSHA256)? = entry["golden_sha256"],
      entry["fixture_sha256"] == .string(fixtureSHA256),
      entry["operation"] == .string(FixtureOperation.sourceLabSite.rawValue),
      path.hasPrefix("ios/harness/goldens/android-legado-v1/")
    else {
      throw ConformanceWorkItemError.goldenNotIndexed
    }

    let goldenURL = try resolve(path, repositoryRoot: repositoryRoot)
    let goldenData: Data
    do {
      goldenData = try Data(contentsOf: goldenURL, options: [.mappedIfSafe])
    } catch {
      throw ConformanceWorkItemError.goldenDigestMismatch
    }
    guard sha256(goldenData) == goldenSHA256 else {
      throw ConformanceWorkItemError.goldenDigestMismatch
    }
    let golden: JSONValue
    do {
      golden = try JSONValueCodec.decode(goldenData)
    } catch {
      throw ConformanceWorkItemError.goldenIdentityMismatch
    }
    guard
      case .object(let goldenRoot) = golden,
      goldenRoot["fixture_id"] == .string(fixtureID),
      goldenRoot["operation"] == .string(FixtureOperation.sourceLabSite.rawValue),
      case .object(let androidArtifact)? = goldenRoot["artifact"],
      androidArtifact["fixture_id"] == .string(fixtureID),
      case .object(var iosArtifact) = artifact,
      iosArtifact["fixture_id"] == .string(fixtureID)
    else {
      throw ConformanceWorkItemError.goldenIdentityMismatch
    }
    let expected = try portableProjection(androidArtifact)
    let actual = try portableProjection(iosArtifact)
    switch CanonicalJSONComparator.compare(expected: expected, actual: actual) {
    case .equal:
      iosArtifact["golden_comparison"] = .object([
        "status": .string("equal"),
        "expected_pointer": .string("/artifact/result/value/portable_known_projection"),
        "expected_sha256": .string(try sha256(JSONValueCodec.encode(expected))),
        "actual_sha256": .string(try sha256(JSONValueCodec.encode(actual))),
        "first_divergence": .null,
      ])
      return .object(iosArtifact)
    case .different(let difference):
      throw GoldenProjectionMismatch(fixtureID: fixtureID, difference: difference)
    }
  }

  private static func portableProjection(_ artifact: [String: JSONValue]) throws -> JSONValue {
    guard
      case .object(let result)? = artifact["result"],
      result["type"] == .string("source_pipeline"),
      case .object(let value)? = result["value"],
      let projection = value["portable_known_projection"]
    else {
      throw ConformanceWorkItemError.goldenProjectionMissing
    }
    return projection
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
