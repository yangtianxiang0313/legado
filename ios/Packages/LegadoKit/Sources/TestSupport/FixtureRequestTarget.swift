import Foundation
import SourceRuntime

public enum FixtureTargetError: String, Error, Codable, Equatable, Sendable {
  case invalidURL = "invalid_url"
  case invalidPath = "invalid_path"
  case invalidQuery = "invalid_query"
  case duplicateQuery = "duplicate_query"
}

public struct FixtureOrigin: Hashable, Sendable {
  public let scheme: String
  public let host: String
  public let port: Int?

  public init(url: HTTPURL) throws {
    guard
      let components = URLComponents(string: url.absoluteString),
      let scheme = components.scheme?.lowercased(),
      let host = components.host?.lowercased(),
      components.user == nil,
      components.password == nil
    else {
      throw FixtureTargetError.invalidURL
    }
    self.scheme = scheme
    self.host = host
    if (scheme == "http" && components.port == 80) || (scheme == "https" && components.port == 443) {
      self.port = nil
    } else {
      self.port = components.port
    }
  }

  public var absoluteString: String {
    port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
  }
}

public struct FixtureQueryItem: Equatable, Sendable {
  public let name: String
  public let value: String

  public init(name: String, value: String) {
    self.name = name
    self.value = value
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    scalarValues(lhs.name) == scalarValues(rhs.name)
      && scalarValues(lhs.value) == scalarValues(rhs.value)
  }
}

public struct FixtureRequestTarget: Equatable, Sendable {
  public let method: HTTPMethod
  public let origin: FixtureOrigin
  public let path: String
  public let query: [FixtureQueryItem]
  private let exactURL: String?

  public init(method: HTTPMethod, url: HTTPURL) throws {
    guard let components = URLComponents(string: url.absoluteString) else {
      throw FixtureTargetError.invalidURL
    }
    let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
    guard path.hasPrefix("/"), !path.hasPrefix("//") else {
      throw FixtureTargetError.invalidPath
    }
    self.method = method
    self.origin = try FixtureOrigin(url: url)
    self.path = path
    self.query = try Self.parseQuery(components.percentEncodedQuery)
    self.exactURL = url.absoluteString
  }

  public init(method: HTTPMethod, sourceLabURL url: HTTPURL, origin: FixtureOrigin) throws {
    let absoluteString = url.absoluteString
    guard absoluteString.hasPrefix(origin.absoluteString) else {
      throw FixtureTargetError.invalidURL
    }
    let target = absoluteString.dropFirst(origin.absoluteString.count)
    guard target.hasPrefix("/"), !target.hasPrefix("//") else {
      throw FixtureTargetError.invalidURL
    }
    let separator = target.firstIndex(of: "?")
    let path = separator.map { String(target[..<$0]) } ?? String(target)
    let query = separator.map { String(target[target.index(after: $0)...]) }
    guard path.hasPrefix("/"), !path.hasPrefix("//") else {
      throw FixtureTargetError.invalidPath
    }
    self.method = method
    self.origin = origin
    self.path = path
    self.query = try Self.parseQuery(query)
    self.exactURL = nil
  }

  public init(
    method: HTTPMethod,
    origin: FixtureOrigin,
    path: String,
    query: [String: String]
  ) throws {
    guard path.hasPrefix("/"), !path.hasPrefix("//") else {
      throw FixtureTargetError.invalidPath
    }
    self.method = method
    self.origin = origin
    self.path = path
    self.query = Self.sorted(
      query.map { FixtureQueryItem(name: $0.key, value: $0.value) }
    )
    self.exactURL = nil
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    guard lhs.method == rhs.method else { return false }
    if lhs.exactURL != nil || rhs.exactURL != nil {
      return lhs.exactURL.map(scalarValues) == rhs.exactURL.map(scalarValues)
    }
    return lhs.origin == rhs.origin
      && scalarValues(lhs.path) == scalarValues(rhs.path)
      && lhs.query == rhs.query
  }

  private static func parseQuery(_ encodedQuery: String?) throws -> [FixtureQueryItem] {
    guard let encodedQuery, !encodedQuery.isEmpty else { return [] }
    let fields = encodedQuery.split(separator: "&", omittingEmptySubsequences: false)
    guard fields.count <= 32, fields.allSatisfy({ !$0.isEmpty }) else {
      throw FixtureTargetError.invalidQuery
    }
    var names: Set<[UInt32]> = []
    var items: [FixtureQueryItem] = []
    for field in fields {
      guard let separator = field.firstIndex(of: "=") else {
        throw FixtureTargetError.invalidQuery
      }
      let name = try decode(field[..<separator])
      let value = try decode(field[field.index(after: separator)...])
      guard names.insert(scalarValues(name)).inserted else {
        throw FixtureTargetError.duplicateQuery
      }
      items.append(FixtureQueryItem(name: name, value: value))
    }
    return sorted(items)
  }

  private static func decode(_ value: Substring) throws -> String {
    let source = Array(value.utf8)
    var bytes: [UInt8] = []
    var index = 0
    while index < source.count {
      if source[index] == 43 {
        bytes.append(32)
        index += 1
      } else if source[index] == 37,
        index + 2 < source.count,
        let high = hex(source[index + 1]),
        let low = hex(source[index + 2])
      {
        bytes.append(high << 4 | low)
        index += 3
      } else {
        bytes.append(source[index])
        index += 1
      }
    }
    return String(decoding: bytes, as: UTF8.self)
  }

  private static func hex(_ byte: UInt8) -> UInt8? {
    switch byte {
    case 48...57:
      byte - 48
    case 65...70:
      byte - 55
    case 97...102:
      byte - 87
    default:
      nil
    }
  }

  private static func sorted(_ items: [FixtureQueryItem]) -> [FixtureQueryItem] {
    items.sorted { lhs, rhs in
      let lhsName = scalarValues(lhs.name)
      let rhsName = scalarValues(rhs.name)
      if lhsName != rhsName {
        return lhsName.lexicographicallyPrecedes(rhsName)
      }
      return scalarValues(lhs.value).lexicographicallyPrecedes(scalarValues(rhs.value))
    }
  }
}

private func scalarValues(_ value: String) -> [UInt32] {
  value.unicodeScalars.map(\.value)
}
