import Foundation
import LegadoCore
import SourceRuntime

struct SourceCookieSessionConformanceRun: Sendable {
  let artifact: JSONValue
  let requestPlan: JSONValue
}

enum SourceCookieSessionConformanceRunner {
  static let fixtureID =
    "sl-source-cookie-persistent-session-merge-runtime-001"

  static func run(
    fixtureDirectory: URL
  ) async throws -> SourceCookieSessionConformanceRun {
    let caseDocument = try json(
      at: fixtureDirectory.appendingPathComponent("case.json")
    )
    let inputDocument = try json(
      at: fixtureDirectory.appendingPathComponent("input.json")
    )
    let sourceDocument = try json(
      at: fixtureDirectory.appendingPathComponent("source.template.json")
    )
    guard
      case .object(let caseRoot) = caseDocument,
      caseRoot["id"] == .string(fixtureID),
      case .object(let determinism)? = caseRoot["determinism"],
      case .string(let origin)? = determinism["logical_origin"],
      case .object(let transportDocument)? = caseRoot["transport"],
      case .array(let responseDocuments)? = transportDocument["responses"],
      case .object(let inputRoot) = inputDocument,
      case .array(let inputCases)? = inputRoot["cases"],
      case .object(let sourceRoot) = sourceDocument
    else {
      throw SourcePipelineConformanceError.invalidSourceDefinition
    }

    let routes = try routeDefinitions(
      responseDocuments,
      fixtureDirectory: fixtureDirectory
    )
    let transport = SourceCookieRouteTransport(routes: routes)
    let sourceHeaders = try sourceHeaders(sourceRoot)
    let storageURL = try HTTPURL("http://127.0.0.1/cookie")
    var plans: [JSONValue] = []
    var projectedCases: [JSONValue] = []

    for value in inputCases {
      guard
        case .object(let inputCase) = value,
        case .string(let id)? = inputCase["id"],
        inputCase["operation"] == .string("cookie_session"),
        case .object(let arguments)? = inputCase["arguments"],
        case .string(let mode)? = arguments["mode"],
        case .object(let requestDocument)? = inputCase["request"],
        requestDocument["method"] == .string("GET"),
        case .string(let target)? = requestDocument["target"],
        target.hasPrefix("/")
      else {
        throw SourcePipelineConformanceError.invalidSourceDefinition
      }
      let request = HTTPRequest(
        method: .get,
        url: try HTTPURL(origin + target),
        headers: sourceHeaders
      )
      let outcome = try await runCase(
        mode: mode,
        arguments: arguments,
        request: request,
        origin: origin,
        storageURL: storageURL,
        transport: transport
      )
      plans.append(requestPlanValue(outcome.plan))
      projectedCases.append(
        .object([
          "id": .string(id),
          "operation": .string("cookie_session"),
          "result": outcome.result,
          "issue": .null,
        ])
      )
    }

    var routeCounts: [JSONValue] = []
    for route in routes {
      let requestCount = await transport.requestCount(routeID: route.id)
      routeCounts.append(.object([
        "request_count": .number(
          JSONNumber(Int64(requestCount))
        ),
        "route_id": .string(route.id),
      ]))
    }
    let canonicalPlans = JSONValue.array(plans)
    let artifact = JSONValue.object([
      "schema_version": .number(JSONNumber(1)),
      "fixture_id": .string(fixtureID),
      "engine": .object([
        "platform": .string("ios"),
        "revision": .string("conformance-source-runtime-v2"),
        "compatibility_profile": .string("android-legado-v1"),
      ]),
      "request_plan": canonicalPlans,
      "decode": .null,
      "stages": .array([]),
      "result": .object([
        "type": .string("source_pipeline"),
        "value": .object([
          "portable_known_projection": .object([
            "cases": .array(projectedCases)
          ]),
          "source_lab_observation": .object([
            "route_request_counts": .array(routeCounts)
          ]),
        ]),
      ]),
      "issues": .array([]),
    ])
    return SourceCookieSessionConformanceRun(
      artifact: artifact,
      requestPlan: canonicalPlans
    )
  }

  private static func runCase(
    mode: String,
    arguments: [String: JSONValue],
    request: HTTPRequest,
    origin: String,
    storageURL: HTTPURL,
    transport: SourceCookieRouteTransport
  ) async throws -> (plan: HTTPRequest, result: JSONValue) {
    switch mode {
    case "parser":
      let raw = try string("cookie", in: arguments)
      let pairs = SourceCookieParser.parse(raw)
      return (
        request,
        .object([
          "entries": .array(
            pairs.map {
              .object([
                "name": .string($0.name),
                "value": .string($0.value),
              ])
            }
          ),
          "serialized": .string(SourceCookieParser.serialize(pairs)),
        ])
      )
    case "store_merge":
      let store = SourceCookieStore()
      try await seed(
        store,
        arguments: arguments,
        storageURL: storageURL
      )
      return (request, snapshotValue(try await store.snapshot(for: storageURL)))
    case "analyze_request":
      return try await analyzeRequest(
        arguments: arguments,
        request: request,
        storageURL: storageURL,
        transport: transport
      )
    case "response_classification":
      let store = SourceCookieStore()
      try await store.saveResponse(
        setCookieHeaders: try strings("set_cookies", in: arguments),
        for: storageURL,
        enabledCookieJar: true
      )
      return (request, snapshotValue(try await store.snapshot(for: storageURL)))
    case "metadata_flattening":
      let store = SourceCookieStore()
      try await store.saveResponse(
        setCookieHeaders: try strings("set_cookies", in: arguments),
        for: storageURL,
        enabledCookieJar: true
      )
      let loadURL = try HTTPURL(origin + string("load_target", in: arguments))
      let snapshot = try await store.snapshot(for: storageURL)
      return (
        request,
        .object([
          "combined_cookie": .string(snapshot.combinedCookie),
          "domain": .string(snapshot.domain),
          "load_url": .string(loadURL.absoluteString),
          "loaded_cookie": .string(snapshot.combinedCookie),
          "persistent_cookie": .string(snapshot.persistentCookie),
          "session_cookie": snapshot.sessionCookie.map(JSONValue.string) ?? .null,
        ])
      )
    case "redirect":
      return try await redirect(
        request: request,
        origin: origin,
        storageURL: storageURL,
        transport: transport
      )
    case "removal":
      let store = SourceCookieStore()
      try await seed(store, arguments: arguments, storageURL: storageURL)
      let before = try await store.snapshot(for: storageURL)
      try await store.removeCookie(
        named: string("remove_key", in: arguments),
        for: storageURL
      )
      let afterKey = try await store.snapshot(for: storageURL)
      try await store.removeCookies(for: storageURL)
      let afterDomain = try await store.snapshot(for: storageURL)
      return (
        request,
        .object([
          "before": snapshotValue(before),
          "after_key_removal": snapshotValue(afterKey),
          "after_domain_removal": snapshotValue(afterDomain),
        ])
      )
    case "domain_normalization":
      let store = SourceCookieStore()
      let writeURL = try HTTPURL(string("write_url", in: arguments))
      let sameSiteURL = try HTTPURL(string("same_site_url", in: arguments))
      let otherSiteURL = try HTTPURL(string("other_site_url", in: arguments))
      try await store.replacePersistentCookie(
        string("cookie", in: arguments),
        for: writeURL
      )
      let write = try await store.snapshot(for: writeURL)
      let sameSite = try await store.snapshot(for: sameSiteURL)
      let otherSite = try await store.snapshot(for: otherSiteURL)
      return (
        request,
        .object([
          "other_site_cookie": .string(otherSite.combinedCookie),
          "other_site_domain": .string(otherSite.domain),
          "same_site_cookie": .string(sameSite.combinedCookie),
          "same_site_domain": .string(sameSite.domain),
          "write_domain": .string(write.domain),
        ])
      )
    default:
      throw SourcePipelineConformanceError.invalidSourceDefinition
    }
  }

  private static func analyzeRequest(
    arguments: [String: JSONValue],
    request: HTTPRequest,
    storageURL: HTTPURL,
    transport: SourceCookieRouteTransport
  ) async throws -> (plan: HTTPRequest, result: JSONValue) {
    guard case .bool(let enabled)? = arguments["enabled_cookie_jar"] else {
      throw SourcePipelineConformanceError.invalidSourceDefinition
    }
    let store = SourceCookieStore()
    try await seed(store, arguments: arguments, storageURL: storageURL)
    let preparation = try await SourceCookieRequestCoordinator.prepare(
      request: request,
      storageURL: storageURL,
      explicitCookie: string("explicit_cookie", in: arguments),
      store: store,
      enabledCookieJar: enabled
    )
    let response = try await transport.execute(preparation.networkRequest)
    try await store.saveResponse(
      setCookieHeaders: response.headers.values(for: "set-cookie"),
      for: storageURL,
      enabledCookieJar: enabled
    )
    let snapshot = try await store.snapshot(for: storageURL)
    return (
      preparation.resolvedRequest,
      .object([
        "combined_cookie": .string(snapshot.combinedCookie),
        "domain": .string(snapshot.domain),
        "enabled_cookie_jar": .bool(enabled),
        "final_url": .string(response.effectiveURL.absoluteString),
        "initial_cookie": .string(preparation.initialCookie),
        "marker_present": .bool(preparation.markerPresent),
        "network_cookie": .string(preparation.networkCookie),
        "network_marker_present": .bool(preparation.networkMarkerPresent),
        "persistent_cookie": .string(snapshot.persistentCookie),
        "resolved_cookie": .string(preparation.resolvedCookie),
        "session_cookie": snapshot.sessionCookie.map(JSONValue.string) ?? .null,
        "status_code": .number(JSONNumber(Int64(response.statusCode))),
      ])
    )
  }

  private static func redirect(
    request: HTTPRequest,
    origin: String,
    storageURL: HTTPURL,
    transport: SourceCookieRouteTransport
  ) async throws -> (plan: HTTPRequest, result: JSONValue) {
    let store = SourceCookieStore()
    let prior = try await SourceCookieRequestCoordinator.prepare(
      request: request,
      storageURL: storageURL,
      explicitCookie: "",
      store: store,
      enabledCookieJar: true
    )
    let priorResponse = try await transport.execute(prior.networkRequest)
    try await store.saveResponse(
      setCookieHeaders: priorResponse.headers.values(for: "set-cookie"),
      for: storageURL,
      enabledCookieJar: true
    )
    guard
      let location = priorResponse.headers.values(for: "location").first,
      location.hasPrefix("/")
    else {
      throw SourcePipelineConformanceError.inputRouteMismatch
    }
    let finalBase = HTTPRequest(
      method: .get,
      url: try HTTPURL(origin + location),
      headers: request.headers
    )
    let final = try await SourceCookieRequestCoordinator.prepare(
      request: finalBase,
      storageURL: storageURL,
      explicitCookie: "",
      store: store,
      enabledCookieJar: true
    )
    let finalResponse = try await transport.execute(final.networkRequest)
    try await store.saveResponse(
      setCookieHeaders: finalResponse.headers.values(for: "set-cookie"),
      for: storageURL,
      enabledCookieJar: true
    )
    let snapshot = try await store.snapshot(for: storageURL)
    return (
      prior.resolvedRequest,
      .object([
        "combined_cookie": .string(snapshot.combinedCookie),
        "domain": .string(snapshot.domain),
        "final_marker_present": .bool(final.networkMarkerPresent),
        "final_request_cookie": .string(final.networkCookie),
        "final_url": .string(finalResponse.effectiveURL.absoluteString),
        "persistent_cookie": .string(snapshot.persistentCookie),
        "prior_marker_present": .bool(prior.markerPresent),
        "prior_request_cookie":
          prior.networkCookie.isEmpty ? .null : .string(prior.networkCookie),
        "redirect_count": .number(JSONNumber(1)),
        "session_cookie": snapshot.sessionCookie.map(JSONValue.string) ?? .null,
        "status_code": .number(JSONNumber(Int64(finalResponse.statusCode))),
      ])
    )
  }

  private static func seed(
    _ store: SourceCookieStore,
    arguments: [String: JSONValue],
    storageURL: HTTPURL
  ) async throws {
    if case .string(let persistent)? = arguments["persistent_cookie"] {
      try await store.replacePersistentCookie(persistent, for: storageURL)
    }
    if case .array? = arguments["session_set_cookies"] {
      try await store.saveResponse(
        setCookieHeaders: try strings("session_set_cookies", in: arguments),
        for: storageURL,
        enabledCookieJar: true
      )
    }
  }

  private static func snapshotValue(_ snapshot: SourceCookieSnapshot) -> JSONValue {
    .object([
      "combined_cookie": .string(snapshot.combinedCookie),
      "domain": .string(snapshot.domain),
      "persistent_cookie": .string(snapshot.persistentCookie),
      "session_cookie": snapshot.sessionCookie.map(JSONValue.string) ?? .null,
    ])
  }

  private static func requestPlanValue(_ request: HTTPRequest) -> JSONValue {
    .object([
      "method": .string(request.method.rawValue),
      "url": .string(request.url.absoluteString),
      "headers": .array(
        request.headers.canonicalFields.map {
          .object([
            "name": .string($0.name),
            "value": .string($0.value),
          ])
        }
      ),
      "body": .null,
      "timeout_ms": .null,
    ])
  }

  private static func string(
    _ key: String,
    in object: [String: JSONValue]
  ) throws -> String {
    guard case .string(let value)? = object[key] else {
      throw SourcePipelineConformanceError.invalidSourceDefinition
    }
    return value
  }

  private static func strings(
    _ key: String,
    in object: [String: JSONValue]
  ) throws -> [String] {
    guard case .array(let values)? = object[key] else {
      throw SourcePipelineConformanceError.invalidSourceDefinition
    }
    return try values.map {
      guard case .string(let value) = $0 else {
        throw SourcePipelineConformanceError.invalidSourceDefinition
      }
      return value
    }
  }

  private static func routeDefinitions(
    _ values: [JSONValue],
    fixtureDirectory: URL
  ) throws -> [SourceCookieRoute] {
    try values.map { value in
      guard
        case .object(let route) = value,
        case .string(let id)? = route["id"],
        case .object(let match)? = route["match"],
        match["method"] == .string("GET"),
        case .string(let path)? = match["path"],
        case .object(let response)? = route["respond"],
        case .number(let statusNumber)? = response["status"],
        let statusCode = Int(statusNumber.rawToken),
        case .object(let rawHeaders)? = response["headers"],
        case .string(let bodyFile)? = response["body_file"]
      else {
        throw SourcePipelineConformanceError.invalidSourceDefinition
      }
      let headers = try rawHeaders.map { name, value in
        guard case .string(let stringValue) = value else {
          throw SourcePipelineConformanceError.invalidSourceDefinition
        }
        return try HTTPHeader(name: name, value: stringValue)
      }
      return SourceCookieRoute(
        id: id,
        path: path,
        statusCode: statusCode,
        headers: HTTPHeaders(headers),
        body: try Data(contentsOf: safeChild(bodyFile, of: fixtureDirectory))
      )
    }
  }

  private static func sourceHeaders(
    _ source: [String: JSONValue]
  ) throws -> HTTPHeaders {
    guard
      case .string(let headerText)? = source["header"],
      case .object(let rawHeaders) =
        try JSONValueCodec.decode(Data(headerText.utf8))
    else {
      throw SourcePipelineConformanceError.invalidSourceDefinition
    }
    return HTTPHeaders(
      try rawHeaders.map { name, value in
        guard case .string(let stringValue) = value else {
          throw SourcePipelineConformanceError.invalidSourceDefinition
        }
        return try HTTPHeader(name: name, value: stringValue)
      }
    )
  }

  private static func safeChild(
    _ relative: String,
    of directory: URL
  ) throws -> URL {
    let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
    guard
      !relative.isEmpty,
      !relative.hasPrefix("/"),
      !relative.contains("\\"),
      parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else {
      throw SourcePipelineConformanceError.invalidSourceDefinition
    }
    let root = directory.standardizedFileURL.resolvingSymlinksInPath()
    let child = root.appendingPathComponent(relative)
      .standardizedFileURL.resolvingSymlinksInPath()
    let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
    guard child.path.hasPrefix(prefix) else {
      throw SourcePipelineConformanceError.invalidSourceDefinition
    }
    return child
  }

  private static func json(at url: URL) throws -> JSONValue {
    try JSONValueCodec.decode(Data(contentsOf: url, options: [.mappedIfSafe]))
  }
}

private struct SourceCookieRoute: Sendable {
  let id: String
  let path: String
  let statusCode: Int
  let headers: HTTPHeaders
  let body: Data
}

private actor SourceCookieRouteTransport: HTTPTransport {
  private let routes: [String: SourceCookieRoute]
  private var counts: [String: Int]

  init(routes: [SourceCookieRoute]) {
    self.routes = Dictionary(uniqueKeysWithValues: routes.map { ($0.path, $0) })
    self.counts = Dictionary(uniqueKeysWithValues: routes.map { ($0.id, 0) })
  }

  func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
    guard
      let components = URLComponents(string: request.url.absoluteString),
      let route = routes[components.percentEncodedPath]
    else {
      throw SourcePipelineConformanceError.inputRouteMismatch
    }
    counts[route.id, default: 0] += 1
    return try HTTPResponse(
      statusCode: route.statusCode,
      effectiveURL: request.url,
      headers: route.headers,
      body: HTTPBody(route.body)
    )
  }

  func requestCount(routeID: String) -> Int {
    counts[routeID, default: 0]
  }
}
