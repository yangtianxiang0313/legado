import Foundation

public enum HTTPMessageValidationError: Error, Equatable, Sendable {
  case invalidURL
  case invalidHeaderName
  case invalidHeaderValue
  case invalidTimeout
  case invalidStatusCode
}

public enum HTTPMethod: String, CaseIterable, Codable, Sendable {
  case get = "GET"
  case post = "POST"
}

public struct HTTPURL: Hashable, Sendable {
  public let absoluteString: String

  public init(_ absoluteString: String) throws {
    guard
      !absoluteString.utf8.contains(where: { $0 <= 32 || $0 == 127 }),
      let components = URLComponents(string: absoluteString),
      let scheme = components.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      components.host?.isEmpty == false,
      components.fragment == nil
    else {
      throw HTTPMessageValidationError.invalidURL
    }
    self.absoluteString = absoluteString
  }
}

extension HTTPURL: Codable {
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    try self.init(container.decode(String.self))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(absoluteString)
  }
}

public struct HTTPHeader: Codable, Equatable, Hashable, Sendable {
  public let name: String
  public let value: String

  public init(name: String, value: String) throws {
    guard Self.isToken(name) else {
      throw HTTPMessageValidationError.invalidHeaderName
    }
    guard !value.utf8.contains(where: { $0 == 0 || $0 == 10 || $0 == 13 }) else {
      throw HTTPMessageValidationError.invalidHeaderValue
    }
    self.name = Self.asciiLowercased(name)
    self.value = value
  }

  private enum CodingKeys: String, CodingKey {
    case name
    case value
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      name: container.decode(String.self, forKey: .name),
      value: container.decode(String.self, forKey: .value)
    )
  }

  private static func isToken(_ value: String) -> Bool {
    let bytes = value.utf8
    return !bytes.isEmpty && bytes.allSatisfy(isTokenByte)
  }

  private static func isTokenByte(_ byte: UInt8) -> Bool {
    switch byte {
    case 48...57, 65...90, 97...122:
      true
    case 33, 35, 36, 37, 38, 39, 42, 43, 45, 46, 94, 95, 96, 124, 126:
      true
    default:
      false
    }
  }

  private static func asciiLowercased(_ value: String) -> String {
    String(
      decoding: value.utf8.map { byte in
        (65...90).contains(byte) ? byte + 32 : byte
      },
      as: UTF8.self
    )
  }
}

public struct HTTPHeaders: Codable, Equatable, Sendable {
  public let fields: [HTTPHeader]

  public init(_ fields: [HTTPHeader] = []) {
    self.fields = fields
  }

  public func values(for name: String) -> [String] {
    guard let normalized = try? HTTPHeader(name: name, value: "").name else { return [] }
    return fields.filter { $0.name == normalized }.map(\.value)
  }

  public var canonicalFields: [HTTPHeader] {
    fields.enumerated().sorted { lhs, rhs in
      if lhs.element.name != rhs.element.name {
        return lhs.element.name < rhs.element.name
      }
      return lhs.offset < rhs.offset
    }.map(\.element)
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    self.init(try container.decode([HTTPHeader].self))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(fields)
  }
}

public struct HTTPBody: Codable, Equatable, Sendable {
  public let bytes: Data

  public init(_ bytes: Data) {
    self.bytes = bytes
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    self.init(try container.decode(Data.self))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(bytes)
  }
}

public struct HTTPResponseCookie: Codable, Equatable, Sendable {
  public let originURL: HTTPURL
  public let name: String
  public let value: String
  public let isPersistent: Bool

  public init(
    originURL: HTTPURL,
    name: String,
    value: String,
    isPersistent: Bool
  ) {
    self.originURL = originURL
    self.name = name
    self.value = value
    self.isPersistent = isPersistent
  }
}

public struct HTTPTimeout: Codable, Equatable, Sendable {
  public let milliseconds: UInt64

  public init(milliseconds: UInt64) throws {
    guard milliseconds > 0 else { throw HTTPMessageValidationError.invalidTimeout }
    self.milliseconds = milliseconds
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    try self.init(milliseconds: container.decode(UInt64.self))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(milliseconds)
  }
}

public enum HTTPProxyType: String, Codable, Equatable, Hashable, Sendable {
  case http
  case socks
}

/// Transport policy carried beside the HTTP fields.
///
/// A source's `proxy` value is a control field in Legado, not an HTTP header.
/// Keeping it on the request makes that distinction survive retries, cookie
/// preparation and transport adapters.
public struct HTTPProxyConfiguration: Codable, Equatable, Hashable, Sendable {
  public let type: HTTPProxyType
  public let host: String
  public let port: UInt16
  public let username: String?
  public let password: String?

  public init(
    type: HTTPProxyType,
    host: String,
    port: UInt16,
    username: String? = nil,
    password: String? = nil
  ) {
    self.type = type
    self.host = host
    self.port = port
    self.username = username
    self.password = password
  }

  private enum CodingKeys: String, CodingKey {
    case type
    case host
    case port
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      type: try container.decode(HTTPProxyType.self, forKey: .type),
      host: try container.decode(String.self, forKey: .host),
      port: try container.decode(UInt16.self, forKey: .port)
    )
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(type, forKey: .type)
    try container.encode(host, forKey: .host)
    try container.encode(port, forKey: .port)
  }
}

public struct HTTPRequest: Codable, Equatable, Sendable {
  public let method: HTTPMethod
  public let url: HTTPURL
  public let headers: HTTPHeaders
  public let body: HTTPBody?
  public let timeout: HTTPTimeout?
  public let proxy: HTTPProxyConfiguration?

  public init(
    method: HTTPMethod,
    url: HTTPURL,
    headers: HTTPHeaders = HTTPHeaders(),
    body: HTTPBody? = nil,
    timeout: HTTPTimeout? = nil,
    proxy: HTTPProxyConfiguration? = nil
  ) {
    self.method = method
    self.url = url
    self.headers = headers
    self.body = body
    self.timeout = timeout
    self.proxy = proxy
  }
}

public struct HTTPResponse: Codable, Equatable, Sendable {
  public let statusCode: Int
  public let effectiveURL: HTTPURL
  public let headers: HTTPHeaders
  public let body: HTTPBody
  public let responseCookies: [HTTPResponseCookie]

  public init(
    statusCode: Int,
    effectiveURL: HTTPURL,
    headers: HTTPHeaders = HTTPHeaders(),
    body: HTTPBody,
    responseCookies: [HTTPResponseCookie] = []
  ) throws {
    guard (100...599).contains(statusCode) else {
      throw HTTPMessageValidationError.invalidStatusCode
    }
    self.statusCode = statusCode
    self.effectiveURL = effectiveURL
    self.headers = headers
    self.body = body
    self.responseCookies = responseCookies
  }

  private enum CodingKeys: String, CodingKey {
    case statusCode
    case effectiveURL
    case headers
    case body
    case responseCookies
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      statusCode: container.decode(Int.self, forKey: .statusCode),
      effectiveURL: container.decode(HTTPURL.self, forKey: .effectiveURL),
      headers: container.decode(HTTPHeaders.self, forKey: .headers),
      body: container.decode(HTTPBody.self, forKey: .body),
      responseCookies: try container.decodeIfPresent(
        [HTTPResponseCookie].self,
        forKey: .responseCookies
      ) ?? []
    )
  }
}
