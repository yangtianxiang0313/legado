import Foundation

public enum SourceRequestPreparationError: Error, Equatable, Sendable {
  case invalidRetry
}

/// A validated header that retains the spelling used by the source.
///
/// `HTTPHeader` deliberately normalizes names for transport. This value remains
/// separate so the source construction and session-injection stages can be
/// observed independently and compared with Android.
public struct SourceHeaderField: Equatable, Sendable {
  public let name: String
  public let value: String

  public init(name: String, value: String) throws {
    _ = try HTTPHeader(name: name, value: value)
    self.name = name
    self.value = value
  }
}

public struct SourceRequestPreparation: Equatable, Sendable {
  public let inheritedHeaders: [SourceHeaderField]
  public let constructedHeaders: [SourceHeaderField]
  public let resolvedHeaders: [SourceHeaderField]
  public let networkHeaders: [SourceHeaderField]
  public let constructedRequest: HTTPRequest
  public let networkRequest: HTTPRequest
  public let proxy: HTTPProxyConfiguration?
  public let retry: Int
}

public enum SourceRequestPreparer {
  public static func prepare(
    request: HTTPRequest,
    inheritedHeaders: [SourceHeaderField],
    optionHeaders: [SourceHeaderField],
    persistentCookie: String,
    enabledCookieJar: Bool,
    retry: Int
  ) throws -> SourceRequestPreparation {
    guard retry >= 0, retry < Int.max else {
      throw SourceRequestPreparationError.invalidRetry
    }

    let overlaid = overlay(inheritedHeaders, with: optionHeaders)
    let proxyText = overlaid.last(where: {
      $0.name.caseInsensitiveCompare("proxy") == .orderedSame
    })?.value
    let proxy = try proxyText.map(SourceProxyConfiguration.init) ?? request.proxy
    let inherited = canonical(
      removingHeaders(named: "proxy", from: inheritedHeaders)
    )
    let constructed = canonical(
      removingHeaders(named: "proxy", from: overlaid)
    )
    let resolved = canonical(
      try resolveSessionHeaders(
        constructed,
        persistentCookie: persistentCookie,
        enabledCookieJar: enabledCookieJar
      )
    )
    let network = canonical(
      try resolveNetworkHeaders(
        resolved,
        persistentCookie: persistentCookie,
        enabledCookieJar: enabledCookieJar
      )
    )

    return SourceRequestPreparation(
      inheritedHeaders: inherited,
      constructedHeaders: constructed,
      resolvedHeaders: resolved,
      networkHeaders: network,
      constructedRequest: try replacingHeaders(
        of: request,
        with: constructed,
        proxy: proxy
      ),
      networkRequest: try replacingHeaders(
        of: request,
        with: network,
        proxy: proxy
      ),
      proxy: proxy,
      retry: retry
    )
  }

  private static func overlay(
    _ inherited: [SourceHeaderField],
    with options: [SourceHeaderField]
  ) -> [SourceHeaderField] {
    var result = inherited
    var positions: [String: Int] = [:]
    for (index, field) in result.enumerated() {
      positions[field.name] = index
    }
    for field in options {
      if let index = positions[field.name] {
        result[index] = field
      } else {
        positions[field.name] = result.count
        result.append(field)
      }
    }
    return result
  }

  private static func resolveSessionHeaders(
    _ headers: [SourceHeaderField],
    persistentCookie: String,
    enabledCookieJar: Bool
  ) throws -> [SourceHeaderField] {
    guard enabledCookieJar else { return headers }
    var result = removingHeaders(named: "Cookie", from: headers)
    let explicitCookie = combinedHeaderValue(named: "Cookie", in: headers)
    let cookie = mergeCookies(persistentCookie, then: explicitCookie)
    if !cookie.isEmpty {
      result.append(try SourceHeaderField(name: "Cookie", value: cookie))
    }
    result = removingHeaders(named: "CookieJar", from: result)
    result.append(try SourceHeaderField(name: "CookieJar", value: "1"))
    return result
  }

  private static func resolveNetworkHeaders(
    _ headers: [SourceHeaderField],
    persistentCookie: String,
    enabledCookieJar: Bool
  ) throws -> [SourceHeaderField] {
    guard enabledCookieJar else { return headers }
    var result = removingHeaders(named: "CookieJar", from: headers)
    let resolvedCookie = combinedHeaderValue(named: "Cookie", in: result)
    result = removingHeaders(named: "Cookie", from: result)
    let cookie = mergeCookies(resolvedCookie, then: persistentCookie)
    if !cookie.isEmpty {
      result.append(try SourceHeaderField(name: "Cookie", value: cookie))
    }
    return result
  }

  private static func removingHeaders(
    named name: String,
    from headers: [SourceHeaderField]
  ) -> [SourceHeaderField] {
    headers.filter { $0.name.caseInsensitiveCompare(name) != .orderedSame }
  }

  private static func combinedHeaderValue(
    named name: String,
    in headers: [SourceHeaderField]
  ) -> String {
    headers
      .filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
      .map(\.value)
      .joined(separator: "; ")
  }

  private static func mergeCookies(_ first: String, then second: String) -> String {
    var pairs: [(name: String, value: String)] = []
    var positions: [String: Int] = [:]
    for rawCookie in [first, second] {
      for rawPair in rawCookie.split(separator: ";", omittingEmptySubsequences: true) {
        let pair = rawPair.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pair.isEmpty else { continue }
        let parts = pair.split(
          separator: "=",
          maxSplits: 1,
          omittingEmptySubsequences: false
        )
        let name = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { continue }
        let value =
          parts.count == 2
          ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
          : ""
        if let index = positions[name] {
          pairs[index].value = value
        } else {
          positions[name] = pairs.count
          pairs.append((name, value))
        }
      }
    }
    return pairs.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
  }

  private static func canonical(_ headers: [SourceHeaderField]) -> [SourceHeaderField] {
    headers.sorted { lhs, rhs in
      let left = lhs.name.lowercased()
      let right = rhs.name.lowercased()
      if left != right { return left < right }
      if lhs.name != rhs.name { return lhs.name < rhs.name }
      return lhs.value < rhs.value
    }
  }

  private static func replacingHeaders(
    of request: HTTPRequest,
    with fields: [SourceHeaderField],
    proxy: HTTPProxyConfiguration?
  ) throws -> HTTPRequest {
    HTTPRequest(
      method: request.method,
      url: request.url,
      headers: HTTPHeaders(
        try fields.map { try HTTPHeader(name: $0.name, value: $0.value) }
      ),
      body: request.body,
      timeout: request.timeout,
      proxy: proxy
    )
  }
}

public struct SourceRequestExecution: Equatable, Sendable {
  public let requestURL: HTTPURL
  public let response: HTTPResponse
  public let attemptCount: Int

  public init(
    requestURL: HTTPURL,
    response: HTTPResponse,
    attemptCount: Int
  ) {
    self.requestURL = requestURL
    self.response = response
    self.attemptCount = attemptCount
  }

  public var effectiveURL: HTTPURL {
    response.effectiveURL
  }

  public var isSuccessful: Bool {
    (200...299).contains(response.statusCode)
  }

  public var redirectObserved: Bool {
    requestURL != response.effectiveURL
  }
}

public struct SourceRequestExecutor: Sendable {
  private let transport: any HTTPTransport

  public init(transport: any HTTPTransport) {
    self.transport = transport
  }

  public func execute(
    _ request: HTTPRequest,
    retry: Int
  ) async throws -> SourceRequestExecution {
    guard retry >= 0, retry < Int.max else {
      throw SourceRequestPreparationError.invalidRetry
    }
    var lastResponse: HTTPResponse?
    for attempt in 1...(retry + 1) {
      try Task.checkCancellation()
      let response = try await transport.execute(request)
      lastResponse = response
      if (200...299).contains(response.statusCode) || attempt == retry + 1 {
        return SourceRequestExecution(
          requestURL: request.url,
          response: response,
          attemptCount: attempt
        )
      }
    }
    // The closed range always executes at least once.
    return SourceRequestExecution(
      requestURL: request.url,
      response: lastResponse!,
      attemptCount: retry + 1
    )
  }
}
