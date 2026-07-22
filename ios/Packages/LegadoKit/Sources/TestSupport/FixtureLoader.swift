import Foundation
import LegadoCore
import SourceRuntime

public enum FixtureLoadingError: String, Error, Codable, Equatable, Sendable {
  case invalidDirectory = "invalid_directory"
  case invalidDefinition = "invalid_definition"
  case pathEscapesFixture = "path_escapes_fixture"
  case missingFile = "missing_file"
  case duplicateRoute = "duplicate_route"
  case networkNotDisabled = "network_not_disabled"
  case invalidLimits = "invalid_limits"
  case bodyTooLarge = "body_too_large"
}

public enum FixtureLoader {
  public static func load(from directory: URL) throws -> LoadedFixture {
    let root = directory.standardizedFileURL.resolvingSymlinksInPath()
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
      throw FixtureLoadingError.invalidDirectory
    }

    let definition: FixtureDefinition = try decode("case.json", from: root)
    guard definition.schemaVersion == 1, definition.id == root.lastPathComponent else {
      throw FixtureLoadingError.invalidDefinition
    }
    guard definition.transport.mode == .offline, definition.determinism.networkAllowed == false else {
      throw FixtureLoadingError.networkNotDisabled
    }
    guard
      definition.limits.timeoutMilliseconds > 0,
      definition.limits.maxResponseBytes > 0,
      definition.limits.maxRequestBodyBytes > 0,
      definition.limits.maxRequests > 0
    else {
      throw FixtureLoadingError.invalidLimits
    }

    let sourceData = try read(definition.source, from: root)
    do {
      _ = try JSONValueCodec.decode(sourceData)
    } catch {
      throw FixtureLoadingError.invalidDefinition
    }
    let input: FixtureInputDefinition = try decode(definition.input, from: root)
    let requestBody = try input.bodyFile.map { try read($0, from: root) }
    if let requestBody, requestBody.count > definition.limits.maxRequestBodyBytes {
      throw FixtureLoadingError.bodyTooLarge
    }
    let request = HTTPRequest(
      method: input.method,
      url: input.url,
      headers: input.headers,
      body: requestBody.map(HTTPBody.init),
      timeout: try HTTPTimeout(milliseconds: UInt64(definition.limits.timeoutMilliseconds))
    )

    var routeKeys: Set<String> = []
    let routes = try definition.transport.responses.map { route in
      let key = "\(route.match.method.rawValue) \(route.match.url.absoluteString)"
      guard routeKeys.insert(key).inserted else { throw FixtureLoadingError.duplicateRoute }
      let body = try read(route.respond.bodyFile, from: root)
      guard body.count <= definition.limits.maxResponseBytes else {
        throw FixtureLoadingError.bodyTooLarge
      }
      return try FixtureRoute(
        id: route.id,
        match: route.match,
        response: HTTPResponse(
          statusCode: route.respond.status,
          effectiveURL: route.respond.effectiveURL,
          headers: route.respond.headers,
          body: HTTPBody(body)
        )
      )
    }
    return LoadedFixture(
      definition: definition,
      sourceData: sourceData,
      request: request,
      routes: routes
    )
  }

  private static func decode<Value: Decodable>(_ relativePath: String, from root: URL) throws -> Value {
    do {
      let data = try read(relativePath, from: root)
      _ = try JSONValueCodec.decode(data)
      return try JSONDecoder().decode(Value.self, from: data)
    } catch let error as FixtureLoadingError {
      throw error
    } catch {
      throw FixtureLoadingError.invalidDefinition
    }
  }

  private static func read(_ relativePath: String, from root: URL) throws -> Data {
    let file = try resolve(relativePath, from: root)
    do {
      return try Data(contentsOf: file, options: [.mappedIfSafe])
    } catch {
      throw FixtureLoadingError.missingFile
    }
  }

  private static func resolve(_ relativePath: String, from root: URL) throws -> URL {
    let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
    guard
      !relativePath.isEmpty,
      !relativePath.hasPrefix("/"),
      !relativePath.contains("\\"),
      !relativePath.contains("\0"),
      components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else {
      throw FixtureLoadingError.pathEscapesFixture
    }

    var candidate = root
    for component in components {
      candidate.appendPathComponent(String(component))
      let values: URLResourceValues
      do {
        values = try candidate.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
      } catch {
        throw FixtureLoadingError.missingFile
      }
      guard values.isSymbolicLink != true else {
        throw FixtureLoadingError.pathEscapesFixture
      }
    }
    let file = candidate.standardizedFileURL.resolvingSymlinksInPath()
    guard file.path.hasPrefix(root.path + "/") else {
      throw FixtureLoadingError.pathEscapesFixture
    }
    let values: URLResourceValues
    do {
      values = try file.resourceValues(forKeys: [.isRegularFileKey])
    } catch {
      throw FixtureLoadingError.missingFile
    }
    guard values.isRegularFile == true else {
      throw FixtureLoadingError.missingFile
    }
    return file
  }
}
