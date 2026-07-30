import Foundation

public enum SourceTransportDispatchError: Error, Equatable, Sendable {
  case invalidDataURI
  case invalidProxy
  case networkRequestRequired
  case unsupportedPOSTBody
}

public enum SourceDispatchReturnKind: Equatable, Sendable {
  case response
  case typedString(type: String)
  case byteArray
  case inputStream
  case dataURI
  case mediaModels
  case clientPolicy
}

public struct SourceDataURI: Equatable, Sendable {
  public let absoluteString: String
  public let mediaType: String
  public let bytes: Data

  public init(_ absoluteString: String) throws {
    guard
      absoluteString.hasPrefix("data:"),
      let comma = absoluteString.firstIndex(of: ",")
    else {
      throw SourceTransportDispatchError.invalidDataURI
    }
    let metadata = String(
      absoluteString[
        absoluteString.index(absoluteString.startIndex, offsetBy: 5)..<comma
      ]
    )
    let components = metadata.split(
      separator: ";",
      omittingEmptySubsequences: false
    )
    guard
      components.last?.lowercased() == "base64",
      let bytes = Data(
        base64Encoded: String(absoluteString[absoluteString.index(after: comma)...])
      )
    else {
      throw SourceTransportDispatchError.invalidDataURI
    }
    self.absoluteString = absoluteString
    self.mediaType = components.dropLast().first.map(String.init) ?? ""
    self.bytes = bytes
  }
}

public enum SourceDispatchTarget: Equatable, Sendable {
  case network(HTTPURL)
  case dataURI(SourceDataURI)

  public var absoluteString: String {
    switch self {
    case .network(let url):
      url.absoluteString
    case .dataURI(let value):
      value.absoluteString
    }
  }
}

public typealias SourceProxyType = HTTPProxyType
public typealias SourceProxyConfiguration = HTTPProxyConfiguration

extension HTTPProxyConfiguration {
  public init(_ value: String) throws {
    guard
      let schemeBoundary = value.range(of: "://"),
      !value[schemeBoundary.upperBound...].isEmpty
    else {
      throw SourceTransportDispatchError.invalidProxy
    }
    let scheme = value[..<schemeBoundary.lowerBound].lowercased()
    let remainder = String(value[schemeBoundary.upperBound...])
    let components = remainder.split(
      separator: "@",
      omittingEmptySubsequences: false
    )
    guard components.count == 1 || components.count == 3 else {
      throw SourceTransportDispatchError.invalidProxy
    }
    let endpoint = String(components[0])
    guard
      let portBoundary = endpoint.lastIndex(of: ":"),
      portBoundary != endpoint.startIndex,
      endpoint.index(after: portBoundary) != endpoint.endIndex
    else {
      throw SourceTransportDispatchError.invalidProxy
    }
    let host = String(endpoint[..<portBoundary])
    let portText = String(endpoint[endpoint.index(after: portBoundary)...])
    guard
      !host.isEmpty,
      !host.contains(where: { "/?#@".contains($0) }),
      let port = Int(portText),
      (1...65_535).contains(port),
      components.count == 1
        || (!components[1].isEmpty && !components[2].isEmpty)
    else {
      throw SourceTransportDispatchError.invalidProxy
    }
    let type: HTTPProxyType
    switch scheme {
    case "http":
      type = .http
    case "socks4", "socks5":
      type = .socks
    default:
      throw SourceTransportDispatchError.invalidProxy
    }
    self.init(
      type: type,
      host: host,
      port: UInt16(port),
      username: components.count == 3 ? String(components[1]) : nil,
      password: components.count == 3 ? String(components[2]) : nil
    )
  }
}

public struct SourceTransportPolicy: Equatable, Sendable {
  public let proxy: SourceProxyConfiguration?
  public let readTimeoutMilliseconds: UInt64?
  public let callTimeoutMilliseconds: UInt64?

  public init(
    proxy: SourceProxyConfiguration? = nil,
    readTimeoutMilliseconds: UInt64? = nil
  ) throws {
    if let readTimeoutMilliseconds, readTimeoutMilliseconds == 0 {
      throw HTTPMessageValidationError.invalidTimeout
    }
    self.proxy = proxy
    self.readTimeoutMilliseconds = readTimeoutMilliseconds
    self.callTimeoutMilliseconds = readTimeoutMilliseconds.map {
      max(60_000, $0.multipliedReportingOverflow(by: 2).overflow ? UInt64.max : $0 * 2)
    }
  }
}

public struct SourceTransportDispatchInput: Equatable, Sendable {
  public let url: String
  public let method: HTTPMethod
  public let body: String?
  public let inheritedHeaders: [SourceHeaderField]
  public let optionHeaders: [SourceHeaderField]
  public let returnKind: SourceDispatchReturnKind
  public let readTimeoutMilliseconds: UInt64?

  public init(
    url: String,
    method: HTTPMethod = .get,
    body: String? = nil,
    inheritedHeaders: [SourceHeaderField] = [],
    optionHeaders: [SourceHeaderField] = [],
    returnKind: SourceDispatchReturnKind,
    readTimeoutMilliseconds: UInt64? = nil
  ) {
    self.url = url
    self.method = method
    self.body = body
    self.inheritedHeaders = inheritedHeaders
    self.optionHeaders = optionHeaders
    self.returnKind = returnKind
    self.readTimeoutMilliseconds = readTimeoutMilliseconds
  }
}

public struct SourceTransportDispatchPlan: Equatable, Sendable {
  public let method: HTTPMethod
  public let target: SourceDispatchTarget
  public let headers: [SourceHeaderField]
  public let body: String?
  public let policy: SourceTransportPolicy
  public let returnKind: SourceDispatchReturnKind
  public let request: HTTPRequest?

  public var timeoutMilliseconds: UInt64? {
    policy.readTimeoutMilliseconds
  }

  public var canonicalHeaders: [HTTPHeader] {
    request?.headers.canonicalFields
      ?? headers.compactMap { try? HTTPHeader(name: $0.name, value: $0.value) }
        .sorted { lhs, rhs in lhs.name < rhs.name }
  }
}

public enum SourceTransportDispatchCompiler {
  public static func compile(
    _ input: SourceTransportDispatchInput
  ) throws -> SourceTransportDispatchPlan {
    var headers = overlay(input.inheritedHeaders, with: input.optionHeaders)
    let proxyText = headers.first(where: { $0.name == "proxy" })?.value
    headers.removeAll { $0.name == "proxy" }
    let proxy = try proxyText.map(SourceProxyConfiguration.init)
    let policy = try SourceTransportPolicy(
      proxy: proxy,
      readTimeoutMilliseconds: input.readTimeoutMilliseconds
    )

    if
      input.method == .post,
      let body = input.body,
      !body.isEmpty,
      !headers.contains(where: { $0.name == "Content-Type" })
    {
      guard looksLikeJSON(body) else {
        throw SourceTransportDispatchError.unsupportedPOSTBody
      }
      headers.append(
        try SourceHeaderField(
          name: "Content-Type",
          value: "application/json; charset=UTF-8"
        )
      )
    }
    let sortedHeaders = canonicalSourceHeaders(headers)
    let target: SourceDispatchTarget
    let request: HTTPRequest?
    if input.url.hasPrefix("data:") {
      target = .dataURI(try SourceDataURI(input.url))
      request = nil
    } else {
      let url = try HTTPURL(input.url)
      target = .network(url)
      request = HTTPRequest(
        method: input.method,
        url: url,
        headers: HTTPHeaders(
          try sortedHeaders.map {
            try HTTPHeader(name: $0.name, value: $0.value)
          }
        ),
        body: input.body.map { HTTPBody(Data($0.utf8)) },
        timeout: try input.readTimeoutMilliseconds.map {
          try HTTPTimeout(milliseconds: $0)
        },
        proxy: proxy
      )
    }
    return SourceTransportDispatchPlan(
      method: input.method,
      target: target,
      headers: sortedHeaders,
      body: input.method == .post ? input.body : nil,
      policy: policy,
      returnKind: input.returnKind,
      request: request
    )
  }

  private static func overlay(
    _ inherited: [SourceHeaderField],
    with options: [SourceHeaderField]
  ) -> [SourceHeaderField] {
    var result = inherited
    var positions = Dictionary(
      uniqueKeysWithValues: inherited.enumerated().map {
        ($0.element.name, $0.offset)
      }
    )
    for header in options {
      if let index = positions[header.name] {
        result[index] = header
      } else {
        positions[header.name] = result.count
        result.append(header)
      }
    }
    return result
  }

  private static func canonicalSourceHeaders(
    _ headers: [SourceHeaderField]
  ) -> [SourceHeaderField] {
    headers.sorted { lhs, rhs in
      let left = lhs.name.lowercased()
      let right = rhs.name.lowercased()
      if left != right { return left < right }
      if lhs.name != rhs.name { return lhs.name < rhs.name }
      return lhs.value < rhs.value
    }
  }

  private static func looksLikeJSON(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return
      (trimmed.hasPrefix("{") && trimmed.hasSuffix("}"))
      || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]"))
  }
}

public struct SourceResponseProjection: Equatable, Sendable {
  public let statusCode: Int
  public let finalURL: HTTPURL
  public let bytes: Data
}

public struct SourceHexStringProjection: Equatable, Sendable {
  public let bodyHex: String
  public let finalURL: HTTPURL
}

public struct SourceDataURIProjection: Equatable, Sendable {
  public let byteArray: Data
  public let inputStreamBytes: Data
}

public struct SourceMediaModels: Equatable, Sendable {
  public let imageURL: String
  public let imageHeaders: [SourceHeaderField]
  public let mediaURL: String
  public let mediaHeaders: [SourceHeaderField]
}

public struct SourceClientPolicyProjection: Equatable, Sendable {
  public let proxyConfigured: Bool
  public let proxyType: SourceProxyType?
  public let readTimeoutMilliseconds: UInt64?
  public let callTimeoutMilliseconds: UInt64?
  public let requestHeaders: [SourceHeaderField]
}

public enum SourceTransportDispatchValue: Equatable, Sendable {
  case response(SourceResponseProjection)
  case hexString(SourceHexStringProjection)
  case byteArray(Data)
  case inputStream(Data)
  case dataURI(SourceDataURIProjection)
  case mediaModels(SourceMediaModels)
  case clientPolicy(SourceClientPolicyProjection)
}

public struct SourceTransportDispatcher: Sendable {
  private let transport: any HTTPTransport

  public init(transport: any HTTPTransport) {
    self.transport = transport
  }

  public func dispatch(
    _ plan: SourceTransportDispatchPlan
  ) async throws -> SourceTransportDispatchValue {
    switch plan.returnKind {
    case .dataURI:
      guard case .dataURI(let value) = plan.target else {
        throw SourceTransportDispatchError.invalidDataURI
      }
      return .dataURI(
        SourceDataURIProjection(
          byteArray: value.bytes,
          inputStreamBytes: value.bytes
        )
      )

    case .mediaModels:
      return .mediaModels(
        SourceMediaModels(
          imageURL: plan.target.absoluteString,
          imageHeaders: plan.headers,
          mediaURL: plan.target.absoluteString,
          mediaHeaders: plan.headers
        )
      )

    case .clientPolicy:
      return .clientPolicy(
        SourceClientPolicyProjection(
          proxyConfigured: plan.policy.proxy != nil,
          proxyType: plan.policy.proxy?.type,
          readTimeoutMilliseconds: plan.policy.readTimeoutMilliseconds,
          callTimeoutMilliseconds: plan.policy.callTimeoutMilliseconds,
          requestHeaders: plan.headers
        )
      )

    case .response, .typedString, .byteArray, .inputStream:
      guard let request = plan.request else {
        throw SourceTransportDispatchError.networkRequestRequired
      }
      let response = try await transport.execute(request)
      switch plan.returnKind {
      case .response:
        return .response(
          SourceResponseProjection(
            statusCode: response.statusCode,
            finalURL: response.effectiveURL,
            bytes: response.body.bytes
          )
        )
      case .typedString:
        return .hexString(
          SourceHexStringProjection(
            bodyHex: hex(response.body.bytes),
            finalURL: response.effectiveURL
          )
        )
      case .byteArray:
        return .byteArray(response.body.bytes)
      case .inputStream:
        return .inputStream(response.body.bytes)
      case .dataURI, .mediaModels, .clientPolicy:
        preconditionFailure("handled before network execution")
      }
    }
  }

  private func hex(_ data: Data) -> String {
    let alphabet = Array("0123456789abcdef".utf8)
    var output: [UInt8] = []
    output.reserveCapacity(data.count * 2)
    for byte in data {
      output.append(alphabet[Int(byte >> 4)])
      output.append(alphabet[Int(byte & 0x0F)])
    }
    return String(decoding: output, as: UTF8.self)
  }
}
