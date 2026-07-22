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
  case invalidLogicalOrigin = "invalid_logical_origin"
  case inputRouteMismatch = "input_route_mismatch"
  case invalidSourceRoundTrip = "invalid_source_round_trip"
}

public enum FixtureLoader {
  public static func loadForConformance(from directory: URL) throws -> LoadedConformanceFixture {
    let root = try validatedRoot(directory)
    let definition: FixtureDefinition = try decode("case.json", from: root)
    guard definition.schemaVersion == 1, definition.id == root.lastPathComponent else {
      throw FixtureLoadingError.invalidDefinition
    }
    guard definition.operation == .sourceRoundTrip else {
      return .transport(try load(from: root))
    }
    guard
      definition.transport.mode == .offline,
      definition.transport.responses.isEmpty,
      definition.determinism.networkAllowed == false,
      definition.determinism.logicalOrigin == nil,
      definition.source == definition.input,
      definition.limits.timeoutMilliseconds > 0,
      definition.limits.maxResponseBytes > 0,
      definition.limits.maxRequestBodyBytes == 0,
      definition.limits.maxRequests == 0,
      definition.limits.maxConcurrency == nil
    else {
      throw FixtureLoadingError.invalidSourceRoundTrip
    }
    let sourceData = try read(definition.source, from: root)
    guard sourceData.count <= definition.limits.maxResponseBytes else {
      throw FixtureLoadingError.bodyTooLarge
    }
    do {
      _ = try JSONValueCodec.decode(sourceData)
    } catch {
      throw FixtureLoadingError.invalidDefinition
    }
    return .sourceRoundTrip(
      LoadedSourceRoundTripFixture(definition: definition, sourceData: sourceData)
    )
  }

  public static func load(from directory: URL) throws -> LoadedFixture {
    let root = try validatedRoot(directory)

    let definition: FixtureDefinition = try decode("case.json", from: root)
    guard definition.schemaVersion == 1, definition.id == root.lastPathComponent else {
      throw FixtureLoadingError.invalidDefinition
    }
    guard definition.determinism.networkAllowed == false else {
      throw FixtureLoadingError.networkNotDisabled
    }
    switch definition.transport.mode {
    case .offline:
      break
    case .fixtureAndLoopback:
      guard definition.transport.externalNetwork == "deny" else {
        throw FixtureLoadingError.networkNotDisabled
      }
    }
    guard
      definition.limits.timeoutMilliseconds > 0,
      definition.limits.maxResponseBytes > 0,
      definition.limits.maxRequestBodyBytes >= 0,
      definition.limits.maxRequests > 0
    else {
      throw FixtureLoadingError.invalidLimits
    }

    let rawSourceData = try read(definition.source, from: root)
    do {
      _ = try JSONValueCodec.decode(rawSourceData)
    } catch {
      throw FixtureLoadingError.invalidDefinition
    }
    let timeout = try HTTPTimeout(milliseconds: UInt64(definition.limits.timeoutMilliseconds))
    let logicalOrigin: FixtureOrigin
    let sourceData: Data
    let requestCases: [FixtureRequestCase]
    if definition.transport.mode == .fixtureAndLoopback {
      guard
        definition.kind == "source_lab_scenario",
        definition.operation == .sourceLabSite,
        let logicalURL = definition.determinism.logicalOrigin
      else {
        throw FixtureLoadingError.invalidLogicalOrigin
      }
      guard
        definition.limits.timeoutMilliseconds <= 5_000,
        definition.limits.maxResponseBytes <= 10 * 1_024 * 1_024,
        definition.limits.maxRequestBodyBytes <= 1_024 * 1_024,
        definition.limits.maxRequests <= 1_000,
        let maxConcurrency = definition.limits.maxConcurrency,
        (1...32).contains(maxConcurrency)
      else {
        throw FixtureLoadingError.invalidLimits
      }
      do {
        logicalOrigin = try FixtureOrigin(url: logicalURL)
      } catch {
        throw FixtureLoadingError.invalidLogicalOrigin
      }
      guard
        logicalURL.absoluteString == logicalOrigin.absoluteString,
        logicalOrigin.absoluteString == "http://sourcelab.test"
      else {
        throw FixtureLoadingError.invalidLogicalOrigin
      }
      sourceData = try renderSource(rawSourceData, origin: logicalOrigin.absoluteString)
      let input: SourceLabInputDefinition = try decode(definition.input, from: root)
      guard input.schemaVersion == 1, !input.cases.isEmpty else {
        throw FixtureLoadingError.invalidDefinition
      }
      var inputIDs: Set<String> = []
      requestCases = try input.cases.map { inputCase in
        guard inputIDs.insert(inputCase.id).inserted else {
          throw FixtureLoadingError.invalidDefinition
        }
        let url = try sourceLabURL(origin: logicalOrigin, target: inputCase.request.target)
        return FixtureRequestCase(
          id: inputCase.id,
          operation: inputCase.operation,
          request: HTTPRequest(method: inputCase.request.method, url: url, timeout: timeout)
        )
      }
    } else {
      sourceData = rawSourceData
      let input: FixtureInputDefinition = try decode(definition.input, from: root)
      do {
        logicalOrigin = try FixtureOrigin(url: input.url)
      } catch {
        throw FixtureLoadingError.invalidDefinition
      }
      let requestBody = try input.bodyFile.map { try read($0, from: root) }
      if let requestBody, requestBody.count > definition.limits.maxRequestBodyBytes {
        throw FixtureLoadingError.bodyTooLarge
      }
      requestCases = [
        FixtureRequestCase(
          id: "default",
          operation: definition.operation,
          request: HTTPRequest(
            method: input.method,
            url: input.url,
            headers: input.headers,
            body: requestBody.map(HTTPBody.init),
            timeout: timeout
          )
        )
      ]
    }

    var routeIDs: Set<String> = []
    var routeTargets: [FixtureRequestTarget] = []
    let routes = try definition.transport.responses.map { route in
      guard routeIDs.insert(route.id).inserted else {
        throw FixtureLoadingError.duplicateRoute
      }
      let target: FixtureRequestTarget
      switch definition.transport.mode {
      case .offline:
        guard
          let url = route.match.url,
          route.match.path == nil,
          route.match.query == nil,
          route.respond.effectiveURL != nil
        else {
          throw FixtureLoadingError.invalidDefinition
        }
        target = try FixtureRequestTarget(method: route.match.method, url: url)
      case .fixtureAndLoopback:
        guard
          route.match.url == nil,
          let path = route.match.path,
          let query = route.match.query,
          route.respond.effectiveURL == nil,
          route.respond.headers.fields.allSatisfy({ Self.allowedSourceLabHeaders.contains($0.name) })
        else {
          throw FixtureLoadingError.invalidDefinition
        }
        target = try FixtureRequestTarget(
          method: route.match.method,
          origin: logicalOrigin,
          path: path,
          query: query
        )
      }
      guard !routeTargets.contains(target) else {
        throw FixtureLoadingError.duplicateRoute
      }
      routeTargets.append(target)
      let body = try read(route.respond.bodyFile, from: root)
      guard body.count <= definition.limits.maxResponseBytes else {
        throw FixtureLoadingError.bodyTooLarge
      }
      guard (100...599).contains(route.respond.status) else {
        throw FixtureLoadingError.invalidDefinition
      }
      return FixtureRoute(
        id: route.id,
        target: target,
        statusCode: route.respond.status,
        effectiveURL: route.respond.effectiveURL,
        headers: route.respond.headers,
        body: HTTPBody(body)
      )
    }
    if definition.transport.mode == .fixtureAndLoopback {
      let routesByID = Dictionary(uniqueKeysWithValues: routes.map { ($0.id, $0) })
      do {
        for requestCase in requestCases {
          let requestTarget = try FixtureRequestTarget(
            method: requestCase.request.method,
            sourceLabURL: requestCase.request.url,
            origin: logicalOrigin
          )
          guard
            let route = routesByID[requestCase.id],
            requestTarget == route.target
          else {
            throw FixtureLoadingError.inputRouteMismatch
          }
        }
      } catch let error as FixtureLoadingError {
        throw error
      } catch {
        throw FixtureLoadingError.inputRouteMismatch
      }
    }
    return try LoadedFixture(
      definition: definition,
      sourceTemplateData: rawSourceData,
      sourceData: sourceData,
      logicalOrigin: logicalOrigin,
      requestCases: requestCases,
      routes: routes
    )
  }

  private static func renderSource(_ data: Data, origin: String) throws -> Data {
    do {
      let template = try JSONValueCodec.decode(data)
      let rendered = replaceStrings(
        template,
        old: "${SOURCE_LAB_ORIGIN}",
        new: origin
      )
      let renderedData = try JSONValueCodec.encode(rendered)
      guard !String(decoding: renderedData, as: UTF8.self).contains("${SOURCE_LAB_ORIGIN}") else {
        throw FixtureLoadingError.invalidDefinition
      }
      return renderedData
    } catch {
      throw FixtureLoadingError.invalidDefinition
    }
  }

  private static func replaceStrings(_ value: JSONValue, old: String, new: String) -> JSONValue {
    switch value {
    case .string(let string):
      .string(string.replacingOccurrences(of: old, with: new))
    case .array(let values):
      .array(values.map { replaceStrings($0, old: old, new: new) })
    case .object(let object):
      .object(object.mapValues { replaceStrings($0, old: old, new: new) })
    case .null, .bool, .number:
      value
    }
  }

  private static func sourceLabURL(origin: FixtureOrigin, target: String) throws -> HTTPURL {
    guard target.hasPrefix("/"), !target.hasPrefix("//") else {
      throw FixtureLoadingError.invalidDefinition
    }
    do {
      return try HTTPURL(origin.absoluteString + target)
    } catch {
      throw FixtureLoadingError.invalidDefinition
    }
  }

  private static let allowedSourceLabHeaders: Set<String> = [
    "cache-control",
    "content-encoding",
    "content-type",
    "location",
    "set-cookie",
  ]

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

  private static func validatedRoot(_ directory: URL) throws -> URL {
    let root = directory.standardizedFileURL.resolvingSymlinksInPath()
    var isDirectory: ObjCBool = false
    guard
      FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw FixtureLoadingError.invalidDirectory
    }
    return root
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
