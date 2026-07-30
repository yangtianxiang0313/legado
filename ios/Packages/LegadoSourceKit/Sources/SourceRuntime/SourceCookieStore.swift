import Foundation

public struct SourceCookiePair: Equatable, Sendable {
  public let name: String
  public let value: String

  public init(name: String, value: String) {
    self.name = name
    self.value = value
  }
}

public enum SourceCookieParser {
  /// Parses the domain-level name/value representation used by Android
  /// `CookieStore.cookieToMap`.
  ///
  /// Empty values and segments without `=` are ignored. Repeated names retain
  /// their first position and replace only the value.
  public static func parse(_ rawCookie: String) -> [SourceCookiePair] {
    var result: [SourceCookiePair] = []
    var positions: [String: Int] = [:]
    for rawSegment in rawCookie.split(
      separator: ";",
      omittingEmptySubsequences: false
    ) {
      let segment = rawSegment.trimmingCharacters(in: .whitespacesAndNewlines)
      let parts = segment.split(
        separator: "=",
        maxSplits: 1,
        omittingEmptySubsequences: false
      )
      guard parts.count == 2 else { continue }
      let name = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
      let value = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty, !value.isEmpty else { continue }
      if let index = positions[name] {
        result[index] = SourceCookiePair(name: name, value: value)
      } else {
        positions[name] = result.count
        result.append(SourceCookiePair(name: name, value: value))
      }
    }
    return result
  }

  public static func serialize(_ pairs: [SourceCookiePair]) -> String {
    pairs.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
  }

  public static func merge(_ layers: [[SourceCookiePair]]) -> [SourceCookiePair] {
    var result: [SourceCookiePair] = []
    var positions: [String: Int] = [:]
    for layer in layers {
      for pair in layer {
        if let index = positions[pair.name] {
          result[index] = pair
        } else {
          positions[pair.name] = result.count
          result.append(pair)
        }
      }
    }
    return result
  }

  public static func merge(_ rawLayers: [String]) -> String {
    serialize(merge(rawLayers.map(parse)))
  }
}

public enum SourceCookieDomain {
  /// Returns the storage key observed from Android's `getSubDomain`.
  ///
  /// The frozen characterization covers IP literals and ordinary registrable
  /// domains. Common two-label public suffixes are retained conservatively;
  /// expanding this table requires a new Android characterization.
  public static func normalized(for url: HTTPURL) throws -> String {
    guard
      let components = URLComponents(string: url.absoluteString),
      let rawHost = components.host?.lowercased(),
      !rawHost.isEmpty
    else {
      throw HTTPMessageValidationError.invalidURL
    }
    let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    if host == "localhost" || host.contains(":") || isIPv4(host) {
      return host
    }
    let labels = host.split(separator: ".").map(String.init)
    guard labels.count > 2 else { return host }
    let twoLabelSuffix = labels.suffix(2).joined(separator: ".")
    let commonTwoLabelSuffixes: Set<String> = [
      "co.jp", "co.uk", "com.au", "com.br", "com.cn", "com.hk",
      "com.sg", "com.tw", "net.cn", "org.cn",
    ]
    if commonTwoLabelSuffixes.contains(twoLabelSuffix), labels.count >= 3 {
      return labels.suffix(3).joined(separator: ".")
    }
    return twoLabelSuffix
  }

  private static func isIPv4(_ host: String) -> Bool {
    let parts = host.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else { return false }
    return parts.allSatisfy { part in
      guard
        !part.isEmpty,
        part.allSatisfy(\.isNumber),
        let value = Int(part),
        (0...255).contains(value)
      else {
        return false
      }
      return true
    }
  }
}

public struct SourceCookieSnapshot: Equatable, Sendable {
  public let domain: String
  public let persistentCookie: String
  public let sessionCookie: String?
  public let combinedCookie: String
}

public protocol SourceCookiePersisting: Sendable {
  func loadPersistentCookie(for domain: String) async throws -> String?
  func savePersistentCookie(
    _ cookie: String?,
    for domain: String
  ) async throws
}

public actor SourceCookieStore {
  private var persistent: [String: [SourceCookiePair]] = [:]
  private var session: [String: [SourceCookiePair]] = [:]
  private var initializedSessionDomains: Set<String> = []
  private var loadedPersistentDomains: Set<String> = []
  private let persistence: (any SourceCookiePersisting)?

  public init(persistence: (any SourceCookiePersisting)? = nil) {
    self.persistence = persistence
  }

  public func replacePersistentCookie(
    _ rawCookie: String,
    for url: HTTPURL
  ) async throws {
    let domain = try SourceCookieDomain.normalized(for: url)
    try await loadPersistentCookieIfNeeded(for: domain)
    persistent[domain] = SourceCookieParser.parse(rawCookie)
    try await persist(domain: domain)
  }

  public func replaceSessionCookie(
    _ rawCookie: String,
    for url: HTTPURL
  ) throws {
    let domain = try SourceCookieDomain.normalized(for: url)
    session[domain] = SourceCookieParser.parse(rawCookie)
    initializedSessionDomains.insert(domain)
  }

  public func saveResponse(
    setCookieHeaders: [String],
    for url: HTTPURL,
    enabledCookieJar: Bool
  ) async throws {
    guard enabledCookieJar else { return }
    let domain = try SourceCookieDomain.normalized(for: url)
    try await loadPersistentCookieIfNeeded(for: domain)
    var persistentUpdates: [SourceCookiePair] = []
    var sessionUpdates: [SourceCookiePair] = []
    for header in setCookieHeaders {
      guard let parsed = Self.responseCookie(header) else { continue }
      if parsed.isPersistent {
        persistentUpdates.append(parsed.pair)
      } else {
        sessionUpdates.append(parsed.pair)
      }
    }
    persistent[domain] = SourceCookieParser.merge([
      persistent[domain] ?? [],
      persistentUpdates,
    ])
    session[domain] = SourceCookieParser.merge([
      session[domain] ?? [],
      sessionUpdates,
    ])
    initializedSessionDomains.insert(domain)
    if !persistentUpdates.isEmpty {
      try await persist(domain: domain)
    }
  }

  public func saveResponse(
    cookies: [HTTPResponseCookie],
    enabledCookieJar: Bool
  ) async throws {
    guard enabledCookieJar else { return }
    var persistentDomains: Set<String> = []
    for cookie in cookies {
      guard !cookie.name.isEmpty, !cookie.value.isEmpty else {
        continue
      }
      let domain = try SourceCookieDomain.normalized(
        for: cookie.originURL
      )
      try await loadPersistentCookieIfNeeded(for: domain)
      let pair = SourceCookiePair(
        name: cookie.name,
        value: cookie.value
      )
      if cookie.isPersistent {
        persistent[domain] = SourceCookieParser.merge([
          persistent[domain] ?? [],
          [pair],
        ])
        persistentDomains.insert(domain)
      } else {
        session[domain] = SourceCookieParser.merge([
          session[domain] ?? [],
          [pair],
        ])
        initializedSessionDomains.insert(domain)
      }
    }
    for domain in persistentDomains.sorted() {
      try await persist(domain: domain)
    }
  }

  public func snapshot(
    for url: HTTPURL
  ) async throws -> SourceCookieSnapshot {
    let domain = try SourceCookieDomain.normalized(for: url)
    try await loadPersistentCookieIfNeeded(for: domain)
    let persistentPairs = persistent[domain] ?? []
    let sessionPairs = session[domain] ?? []
    let persistentCookie = SourceCookieParser.serialize(persistentPairs)
    let sessionCookie =
      initializedSessionDomains.contains(domain)
      ? SourceCookieParser.serialize(sessionPairs)
      : nil
    return SourceCookieSnapshot(
      domain: domain,
      persistentCookie: persistentCookie,
      sessionCookie: sessionCookie,
      combinedCookie: SourceCookieParser.serialize(
        SourceCookieParser.merge([persistentPairs, sessionPairs])
      )
    )
  }

  public func removeCookie(
    named name: String,
    for url: HTTPURL
  ) async throws {
    let domain = try SourceCookieDomain.normalized(for: url)
    try await loadPersistentCookieIfNeeded(for: domain)
    persistent[domain] = (persistent[domain] ?? []).filter { $0.name != name }
    if initializedSessionDomains.contains(domain) {
      session[domain] = (session[domain] ?? []).filter { $0.name != name }
    }
    try await persist(domain: domain)
  }

  public func removeCookies(for url: HTTPURL) async throws {
    let domain = try SourceCookieDomain.normalized(for: url)
    persistent.removeValue(forKey: domain)
    session.removeValue(forKey: domain)
    initializedSessionDomains.remove(domain)
    loadedPersistentDomains.insert(domain)
    try await persistence?.savePersistentCookie(nil, for: domain)
  }

  private func loadPersistentCookieIfNeeded(
    for domain: String
  ) async throws {
    guard loadedPersistentDomains.insert(domain).inserted else {
      return
    }
    guard
      let raw = try await persistence?.loadPersistentCookie(
        for: domain
      )
    else {
      return
    }
    persistent[domain] = SourceCookieParser.parse(raw)
  }

  private func persist(domain: String) async throws {
    guard let persistence else { return }
    let value = SourceCookieParser.serialize(
      persistent[domain] ?? []
    )
    try await persistence.savePersistentCookie(
      value.isEmpty ? nil : value,
      for: domain
    )
  }

  private static func responseCookie(
    _ header: String
  ) -> (pair: SourceCookiePair, isPersistent: Bool)? {
    let segments = header.split(
      separator: ";",
      omittingEmptySubsequences: false
    )
    guard let first = segments.first else { return nil }
    let pairParts = first.split(
      separator: "=",
      maxSplits: 1,
      omittingEmptySubsequences: false
    )
    guard pairParts.count == 2 else { return nil }
    let name = String(pairParts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
    let value = String(pairParts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, !value.isEmpty else { return nil }
    let attributes = segments.dropFirst().map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    return (
      SourceCookiePair(name: name, value: value),
      attributes.contains {
        $0.hasPrefix("max-age=") || $0.hasPrefix("expires=")
      }
    )
  }
}

public struct SourceCookieRequestPreparation: Equatable, Sendable {
  public let initialCookie: String
  public let resolvedCookie: String
  public let networkCookie: String
  public let markerPresent: Bool
  public let networkMarkerPresent: Bool
  public let resolvedRequest: HTTPRequest
  public let networkRequest: HTTPRequest
}

public enum SourceCookieRequestCoordinator {
  public static func prepare(
    request: HTTPRequest,
    storageURL: HTTPURL,
    explicitCookie: String,
    store: SourceCookieStore,
    enabledCookieJar: Bool
  ) async throws -> SourceCookieRequestPreparation {
    let snapshot = try await store.snapshot(for: storageURL)
    let initial = SourceCookieParser.serialize(
      SourceCookieParser.parse(explicitCookie)
    )
    let resolved = SourceCookieParser.merge([
      snapshot.combinedCookie,
      initial,
    ])
    let network =
      enabledCookieJar
      ? SourceCookieParser.merge([resolved, snapshot.combinedCookie])
      : resolved
    return try SourceCookieRequestPreparation(
      initialCookie: initial,
      resolvedCookie: resolved,
      networkCookie: network,
      markerPresent: enabledCookieJar,
      networkMarkerPresent: false,
      resolvedRequest: replacingCookieHeaders(
        request,
        cookie: resolved,
        marker: enabledCookieJar
      ),
      networkRequest: replacingCookieHeaders(
        request,
        cookie: network,
        marker: false
      )
    )
  }

  private static func replacingCookieHeaders(
    _ request: HTTPRequest,
    cookie: String,
    marker: Bool
  ) throws -> HTTPRequest {
    var fields = request.headers.fields.filter {
      $0.name != "cookie" && $0.name != "cookiejar"
    }
    if !cookie.isEmpty {
      fields.append(try HTTPHeader(name: "cookie", value: cookie))
    }
    if marker {
      fields.append(try HTTPHeader(name: "cookiejar", value: "1"))
    }
    return HTTPRequest(
      method: request.method,
      url: request.url,
      headers: HTTPHeaders(fields),
      body: request.body,
      timeout: request.timeout,
      proxy: request.proxy
    )
  }
}

public struct SourceRequestSession: Sendable {
  private let transport: any HTTPTransport
  private let cookieStore: SourceCookieStore

  public init(
    transport: any HTTPTransport,
    cookieStore: SourceCookieStore
  ) {
    self.transport = transport
    self.cookieStore = cookieStore
  }

  public func execute(
    _ plan: SourceRequestPlan,
    enabledCookieJar: Bool
  ) async throws -> SourceRequestExecution {
    let explicitCookie = plan.request.headers
      .values(for: "cookie")
      .joined(separator: "; ")
    let preparation = try await SourceCookieRequestCoordinator.prepare(
      request: plan.request,
      storageURL: plan.request.url,
      explicitCookie: explicitCookie,
      store: cookieStore,
      enabledCookieJar: enabledCookieJar
    )
    let execution = try await SourceRequestExecutor(
      transport: transport
    ).execute(preparation.networkRequest, retry: plan.retry)
    if execution.response.responseCookies.isEmpty {
      try await cookieStore.saveResponse(
        setCookieHeaders: execution.response.headers.values(
          for: "set-cookie"
        ),
        for: execution.effectiveURL,
        enabledCookieJar: enabledCookieJar
      )
    } else {
      try await cookieStore.saveResponse(
        cookies: execution.response.responseCookies,
        enabledCookieJar: enabledCookieJar
      )
    }
    return execution
  }
}
