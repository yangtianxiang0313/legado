import Foundation
import LegadoCore
import SourceRuntime

struct SourceDynamicWebConformanceRun: Sendable {
  let artifact: JSONValue
  let requestPlan: JSONValue
}

enum SourceDynamicWebConformanceRunner {
  static let fixtureID = "sl-source-transport-dynamic-web-runtime-001"

  static func run(
    fixtureDirectory: URL
  ) async throws -> SourceDynamicWebConformanceRun {
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
    let environment = DynamicWebFixtureEnvironment(routes: routes)
    let sourceConfiguration = try sourceConfiguration(sourceRoot)
    let storageURL = try HTTPURL("http://127.0.0.1/dynamic")
    var plans: [JSONValue] = []
    var cases: [JSONValue] = []

    for value in inputCases {
      guard
        case .object(let inputCase) = value,
        case .string(let id)? = inputCase["id"],
        inputCase["operation"] == .string("dynamic_web"),
        case .object(let arguments)? = inputCase["arguments"],
        case .object(let requestDocument)? = inputCase["request"],
        case .string(let methodText)? = requestDocument["method"],
        let method = HTTPMethod(rawValue: methodText),
        case .string(let target)? = requestDocument["target"],
        target.hasPrefix("/"),
        case .bool(let optionUseWebView)? = arguments["option_use_webview"],
        case .bool(let invocationUseWebView)? =
          arguments["invocation_use_webview"]
      else {
        throw SourcePipelineConformanceError.invalidSourceDefinition
      }
      let body: String?
      if method == .post {
        body = try string("body", in: arguments)
      } else {
        body = nil
      }
      let request = HTTPRequest(
        method: method,
        url: try HTTPURL(origin + target),
        headers: HTTPHeaders([
          try HTTPHeader(
            name: "x-source",
            value: sourceConfiguration.sourceHeader
          )
        ]),
        body: body.map { HTTPBody(Data($0.utf8)) }
      )
      plans.append(requestPlanValue(request))
      let store = SourceCookieStore()
      let before = try await store.snapshot(for: storageURL)
      let webJavaScript = try optionalString("web_js", in: arguments)
      let sourceRegex = try optionalString("source_regex", in: arguments)
      let execution = try await SourceDynamicWebExecutor(
        transport: environment,
        pagePort: environment
      ).execute(
        request: request,
        configuration: SourceDynamicWebConfiguration(
          optionUseWebView: optionUseWebView,
          invocationUseWebView: invocationUseWebView,
          javaScript: webJavaScript,
          sourceRegex: sourceRegex,
          userAgent: sourceConfiguration.userAgent
        ),
        cookieStore: store,
        cookieStorageURL: storageURL
      )
      let after = try await store.snapshot(for: storageURL)
      cases.append(
        .object([
          "id": .string(id),
          "operation": .string("dynamic_web"),
          "result": .object([
            "body": .string(execution.body),
            "configured_use_webview": .bool(optionUseWebView),
            "configured_web_js":
              webJavaScript.map(JSONValue.string) ?? .null,
            "final_url": .string(execution.finalURL.absoluteString),
            "invocation_use_webview": .bool(invocationUseWebView),
            "source_cookie_after": .string(after.combinedCookie),
            "source_cookie_before": .string(before.combinedCookie),
            "source_regex": sourceRegex.map(JSONValue.string) ?? .null,
            "web_cookie_after":
              execution.webCookie.map(JSONValue.string) ?? .null,
            "web_cookie_before": .null,
          ]),
          "issue": .null,
        ])
      )
    }

    var routeCounts: [JSONValue] = []
    for route in routes {
      let count = await environment.requestCount(routeID: route.id)
      routeCounts.append(
        .object([
          "request_count": .number(JSONNumber(Int64(count))),
          "route_id": .string(route.id),
        ])
      )
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
            "cases": .array(cases)
          ]),
          "source_lab_observation": .object([
            "route_request_counts": .array(routeCounts)
          ]),
        ]),
      ]),
      "issues": .array([]),
    ])
    return SourceDynamicWebConformanceRun(
      artifact: artifact,
      requestPlan: canonicalPlans
    )
  }

  private static func sourceConfiguration(
    _ source: [String: JSONValue]
  ) throws -> (sourceHeader: String, userAgent: String?) {
    guard
      case .string(let headerText)? = source["header"],
      case .object(let headers) =
        try JSONValueCodec.decode(Data(headerText.utf8)),
      case .string(let sourceHeader)? = headers["X-Source"]
    else {
      throw SourcePipelineConformanceError.invalidSourceDefinition
    }
    let userAgent: String?
    if case .string(let value)? = headers["User-Agent"] {
      userAgent = value
    } else {
      userAgent = nil
    }
    return (sourceHeader, userAgent)
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
      "body": request.body.map {
        .string(String(decoding: $0.bytes, as: UTF8.self))
      } ?? .null,
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

  private static func optionalString(
    _ key: String,
    in object: [String: JSONValue]
  ) throws -> String? {
    switch object[key] {
    case .string(let value)?:
      return value
    case .null?:
      return nil
    default:
      throw SourcePipelineConformanceError.invalidSourceDefinition
    }
  }

  private static func routeDefinitions(
    _ values: [JSONValue],
    fixtureDirectory: URL
  ) throws -> [DynamicWebRoute] {
    try values.map { value in
      guard
        case .object(let route) = value,
        case .string(let id)? = route["id"],
        case .object(let match)? = route["match"],
        case .string(let methodText)? = match["method"],
        let method = HTTPMethod(rawValue: methodText),
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
      return DynamicWebRoute(
        id: id,
        method: method,
        path: path,
        statusCode: statusCode,
        headers: HTTPHeaders(headers),
        body: try Data(contentsOf: safeChild(bodyFile, of: fixtureDirectory))
      )
    }
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

private struct DynamicWebRoute: Sendable {
  let id: String
  let method: HTTPMethod
  let path: String
  let statusCode: Int
  let headers: HTTPHeaders
  let body: Data
}

private actor DynamicWebFixtureEnvironment:
  HTTPTransport,
  SourceDynamicWebPagePort
{
  private let routes: [String: DynamicWebRoute]
  private var counts: [String: Int]

  init(routes: [DynamicWebRoute]) {
    self.routes = Dictionary(uniqueKeysWithValues: routes.map {
      (Self.key(method: $0.method, path: $0.path), $0)
    })
    self.counts = Dictionary(uniqueKeysWithValues: routes.map { ($0.id, 0) })
  }

  func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
    let route = try route(method: request.method, url: request.url)
    counts[route.id, default: 0] += 1
    return try HTTPResponse(
      statusCode: route.statusCode,
      effectiveURL: request.url,
      headers: route.headers,
      body: HTTPBody(route.body)
    )
  }

  func execute(
    _ request: SourceDynamicWebPageRequest
  ) async throws -> SourceDynamicWebPageResult {
    let html: String
    let responseHeaders: HTTPHeaders
    switch request.mode {
    case .loadURL:
      let route = try route(method: .get, url: request.url)
      counts[route.id, default: 0] += 1
      html = String(decoding: route.body, as: UTF8.self)
      responseHeaders = route.headers
    case .injectHTML:
      guard let injected = request.html else {
        throw SourcePipelineConformanceError.invalidSourceDefinition
      }
      html = injected
      responseHeaders = HTTPHeaders()
    }

    let webCookie = responseHeaders.values(for: "set-cookie")
      .first
      .flatMap(cookiePair)
    if let sourceRegex = request.sourceRegex,
      let resourceURL = try matchedResource(
        in: html,
        baseURL: request.url,
        regex: sourceRegex
      )
    {
      let resourceRoute = try route(method: .get, url: resourceURL)
      counts[resourceRoute.id, default: 0] += 1
      return SourceDynamicWebPageResult(
        finalURL: request.url,
        value: resourceURL.absoluteString,
        completionKind: .resource,
        webCookie: webCookie
      )
    }
    return SourceDynamicWebPageResult(
      finalURL: request.url,
      value: try evaluate(
        request.javaScript,
        html: html,
        userAgent: request.userAgent
      ),
      completionKind: .javaScript,
      webCookie: webCookie
    )
  }

  func requestCount(routeID: String) -> Int {
    counts[routeID, default: 0]
  }

  private func route(
    method: HTTPMethod,
    url: HTTPURL
  ) throws -> DynamicWebRoute {
    guard
      let components = URLComponents(string: url.absoluteString),
      let route = routes[Self.key(
        method: method,
        path: components.percentEncodedPath
      )]
    else {
      throw SourcePipelineConformanceError.inputRouteMismatch
    }
    return route
  }

  private func matchedResource(
    in html: String,
    baseURL: HTTPURL,
    regex: String
  ) throws -> HTTPURL? {
    let pattern = #"(?:src|href)=["']([^"']+)["']"#
    let expression = try NSRegularExpression(pattern: pattern)
    let range = NSRange(html.startIndex..<html.endIndex, in: html)
    for match in expression.matches(in: html, range: range) {
      guard
        let valueRange = Range(match.range(at: 1), in: html),
        let base = URL(string: baseURL.absoluteString),
        let resolved = URL(
          string: String(html[valueRange]),
          relativeTo: base
        )?.absoluteURL
      else {
        continue
      }
      let candidate = try HTTPURL(resolved.absoluteString)
      let candidateRange = NSRange(
        candidate.absoluteString.startIndex..<candidate.absoluteString.endIndex,
        in: candidate.absoluteString
      )
      let resourceExpression = try NSRegularExpression(pattern: regex)
      if
        let result = resourceExpression.firstMatch(
          in: candidate.absoluteString,
          range: candidateRange
        ),
        result.range == candidateRange
      {
        return candidate
      }
    }
    return nil
  }

  private func evaluate(
    _ script: String,
    html: String,
    userAgent: String?
  ) throws -> String {
    if script == "navigator.userAgent" {
      return userAgent ?? ""
    }
    if script == SourceDynamicWebExecutor.defaultJavaScript {
      return normalizedOuterHTML(html)
    }
    let expression = try NSRegularExpression(
      pattern: #"document\.getElementById\('([^']+)'\)\.textContent"#
    )
    let scriptRange = NSRange(script.startIndex..<script.endIndex, in: script)
    guard
      let match = expression.firstMatch(in: script, range: scriptRange),
      let idRange = Range(match.range(at: 1), in: script)
    else {
      throw SourcePipelineConformanceError.invalidSourceDefinition
    }
    let identifier = NSRegularExpression.escapedPattern(
      for: String(script[idRange])
    )
    let element = try NSRegularExpression(
      pattern:
        #"<[^>]*\bid=["']"# + identifier
        + #"["'][^>]*>(.*?)</[^>]+>"#,
      options: [.dotMatchesLineSeparators]
    )
    let htmlRange = NSRange(html.startIndex..<html.endIndex, in: html)
    guard
      let elementMatch = element.firstMatch(in: html, range: htmlRange),
      let contentRange = Range(elementMatch.range(at: 1), in: html)
    else {
      throw SourcePipelineConformanceError.invalidSourceDefinition
    }
    return String(html[contentRange])
      .replacingOccurrences(
        of: #"<[^>]+>"#,
        with: "",
        options: .regularExpression
      )
  }

  private func normalizedOuterHTML(_ html: String) -> String {
    var value = html.replacingOccurrences(
      of: #"(?i)^<!doctype html>"#,
      with: "",
      options: .regularExpression
    )
    if value.hasSuffix("\n") {
      value.removeLast()
      if let bodyEnd = value.range(of: "</body>") {
        value.insert("\n", at: bodyEnd.lowerBound)
      }
    }
    return value
  }

  private func cookiePair(_ setCookie: String) -> String? {
    let first = setCookie.split(
      separator: ";",
      maxSplits: 1,
      omittingEmptySubsequences: false
    ).first?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return first?.isEmpty == false ? first : nil
  }

  private static func key(method: HTTPMethod, path: String) -> String {
    method.rawValue + "\u{0}" + path
  }
}
