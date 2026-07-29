import Foundation
import LegadoCore
import SourceRuntime

struct SourceTransportDispatchConformanceRun: Sendable {
  let artifact: JSONValue
  let requestPlan: JSONValue
}

enum SourceTransportDispatchConformanceRunner {
  static let fixtureID = "sl-source-transport-request-dispatch-contract-001"

  static func run(
    fixtureDirectory: URL
  ) async throws -> SourceTransportDispatchConformanceRun {
    let caseDocument = try json(at: fixtureDirectory.appendingPathComponent("case.json"))
    let inputDocument = try json(at: fixtureDirectory.appendingPathComponent("input.json"))
    let sourceDocument = try json(
      at: fixtureDirectory.appendingPathComponent("source.template.json")
    )
    guard
      case .object(let caseRoot) = caseDocument,
      caseRoot["id"] == .string(fixtureID),
      case .object(let determinism)? = caseRoot["determinism"],
      case .string(let origin)? = determinism["logical_origin"],
      origin == "http://sourcelab.test",
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
      origin: origin,
      fixtureDirectory: fixtureDirectory
    )
    let transport = SourceDispatchFixtureTransport(routes: routes)
    let dispatcher = SourceTransportDispatcher(transport: transport)
    let inheritedHeaders = try sourceHeaders(sourceRoot)
    var plans: [JSONValue] = []
    var cases: [JSONValue] = []

    for inputCaseValue in inputCases {
      guard
        case .object(let inputCase) = inputCaseValue,
        case .string(let id)? = inputCase["id"],
        inputCase["operation"] == .string("transport_dispatch"),
        case .object(let arguments)? = inputCase["arguments"],
        case .object(let request)? = inputCase["request"],
        case .string(let methodText)? = request["method"],
        let method = HTTPMethod(rawValue: methodText),
        case .string(let target)? = request["target"],
        case .string(let mode)? = arguments["mode"]
      else {
        throw SourcePipelineConformanceError.invalidSourceDefinition
      }

      let compiled = try compile(
        origin: origin,
        target: target,
        method: method,
        mode: mode,
        arguments: arguments,
        inheritedHeaders: inheritedHeaders
      )
      plans.append(requestPlanValue(compiled))
      let dispatched = try await dispatcher.dispatch(compiled)
      cases.append(
        .object([
          "id": .string(id),
          "operation": .string("transport_dispatch"),
          "result": try resultValue(dispatched),
          "issue": .null,
        ])
      )
    }

    var routeCounts: [JSONValue] = []
    for route in routes {
      let count = await transport.requestCount(routeID: route.id)
      routeCounts.append(
        .object([
          "request_count": .number(JSONNumber(Int64(count))),
          "route_id": .string(route.id),
        ])
      )
    }
    let canonicalPlans = JSONValue.array(plans)
    let resultValue = JSONValue.object([
      "portable_known_projection": .object([
        "cases": .array(cases)
      ]),
      "source_lab_observation": .object([
        "route_request_counts": .array(routeCounts)
      ]),
    ])
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
        "value": resultValue,
      ]),
      "issues": .array([]),
    ])
    return SourceTransportDispatchConformanceRun(
      artifact: artifact,
      requestPlan: canonicalPlans
    )
  }

  private static func compile(
    origin: String,
    target: String,
    method: HTTPMethod,
    mode: String,
    arguments: [String: JSONValue],
    inheritedHeaders: [SourceHeaderField]
  ) throws -> SourceTransportDispatchPlan {
    let returnKind: SourceDispatchReturnKind
    switch mode {
    case "response":
      returnKind = .response
    case "typed_string":
      guard case .string(let type)? = arguments["type"] else {
        throw SourcePipelineConformanceError.invalidSourceDefinition
      }
      returnKind = .typedString(type: type)
    case "byte_array":
      returnKind = .byteArray
    case "input_stream":
      returnKind = .inputStream
    case "data_uri":
      returnKind = .dataURI
    case "media_models":
      returnKind = .mediaModels
    case "client_policy":
      returnKind = .clientPolicy
    default:
      throw SourcePipelineConformanceError.invalidSourceDefinition
    }

    let body: String?
    if case .string(let value)? = arguments["body"] {
      body = value
    } else {
      body = nil
    }
    var optionHeaders: [SourceHeaderField] = []
    if case .string(let contentType)? = arguments["content_type"] {
      optionHeaders.append(
        try SourceHeaderField(name: "Content-Type", value: contentType)
      )
    }
    if
      case .string(let name)? = arguments["header_name"],
      case .string(let value)? = arguments["header_value"]
    {
      optionHeaders.append(try SourceHeaderField(name: name, value: value))
    }
    let sourceHeaders: [SourceHeaderField]
    let timeout: UInt64?
    if mode == "client_policy" {
      guard
        case .string(let proxy)? = arguments["proxy"],
        case .number(let timeoutNumber)? = arguments["read_timeout_ms"],
        let timeoutValue = UInt64(timeoutNumber.rawToken)
      else {
        throw SourcePipelineConformanceError.invalidSourceDefinition
      }
      sourceHeaders = [
        try SourceHeaderField(name: "proxy", value: proxy),
        try SourceHeaderField(name: "X-Policy", value: "source"),
      ]
      timeout = timeoutValue
    } else {
      sourceHeaders = inheritedHeaders
      timeout = nil
    }
    let url =
      target.hasPrefix("data:")
      ? target
      : origin + target
    return try SourceTransportDispatchCompiler.compile(
      SourceTransportDispatchInput(
        url: url,
        method: method,
        body: body,
        inheritedHeaders: sourceHeaders,
        optionHeaders: optionHeaders,
        returnKind: returnKind,
        readTimeoutMilliseconds: timeout
      )
    )
  }

  private static func requestPlanValue(
    _ plan: SourceTransportDispatchPlan
  ) -> JSONValue {
    .object([
      "method": .string(plan.method.rawValue),
      "url": .string(plan.target.absoluteString),
      "headers": .array(
        plan.canonicalHeaders.map {
          .object([
            "name": .string($0.name),
            "value": .string($0.value),
          ])
        }
      ),
      "body": plan.body.map(JSONValue.string) ?? .null,
      "timeout_ms": plan.timeoutMilliseconds.map {
        .number(JSONNumber(Int64($0)))
      } ?? .null,
    ])
  }

  private static func resultValue(
    _ value: SourceTransportDispatchValue
  ) throws -> JSONValue {
    switch value {
    case .response(let response):
      .object([
        "body_base64": .string(response.bytes.base64EncodedString()),
        "byte_count": .number(JSONNumber(Int64(response.bytes.count))),
        "final_url": .string(response.finalURL.absoluteString),
        "status_code": .number(JSONNumber(Int64(response.statusCode))),
      ])

    case .hexString(let response):
      .object([
        "body_hex": .string(response.bodyHex),
        "final_url": .string(response.finalURL.absoluteString),
      ])

    case .byteArray(let bytes), .inputStream(let bytes):
      .object([
        "byte_count": .number(JSONNumber(Int64(bytes.count))),
        "bytes_base64": .string(bytes.base64EncodedString()),
      ])

    case .dataURI(let projection):
      .object([
        "byte_array_base64": .string(
          projection.byteArray.base64EncodedString()
        ),
        "input_stream_base64": .string(
          projection.inputStreamBytes.base64EncodedString()
        ),
        "same_bytes": .bool(
          projection.byteArray == projection.inputStreamBytes
        ),
      ])

    case .mediaModels(let models):
      .object([
        "glide_headers": sourceHeaderValue(models.imageHeaders),
        "glide_url": .string(models.imageURL),
        "media_headers": sourceHeaderValue(models.mediaHeaders),
        "media_url": .string(models.mediaURL),
      ])

    case .clientPolicy(let policy):
      .object([
        "call_timeout_ms": policy.callTimeoutMilliseconds.map {
          .number(JSONNumber(Int64($0)))
        } ?? .null,
        "proxy_configured": .bool(policy.proxyConfigured),
        "proxy_header_removed": .bool(
          !policy.requestHeaders.contains { $0.name == "proxy" }
        ),
        "proxy_type": policy.proxyType.map {
          .string($0.rawValue)
        } ?? .null,
        "read_timeout_ms": policy.readTimeoutMilliseconds.map {
          .number(JSONNumber(Int64($0)))
        } ?? .null,
        "request_headers": sourceHeaderValue(policy.requestHeaders),
      ])
    }
  }

  private static func sourceHeaderValue(
    _ headers: [SourceHeaderField]
  ) -> JSONValue {
    .array(
      headers.map {
        .object([
          "name": .string($0.name),
          "value": .string($0.value),
        ])
      }
    )
  }

  private static func sourceHeaders(
    _ source: [String: JSONValue]
  ) throws -> [SourceHeaderField] {
    guard case .string(let headerText)? = source["header"] else { return [] }
    guard
      case .object(let headers) =
        try JSONValueCodec.decode(Data(headerText.utf8))
    else {
      throw SourcePipelineConformanceError.invalidSourceDefinition
    }
    return try headers.map { name, value in
      guard case .string(let stringValue) = value else {
        throw SourcePipelineConformanceError.invalidSourceDefinition
      }
      return try SourceHeaderField(name: name, value: stringValue)
    }
  }

  private static func routeDefinitions(
    _ values: [JSONValue],
    origin: String,
    fixtureDirectory: URL
  ) throws -> [SourceDispatchFixtureRoute] {
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
        let status = Int(statusNumber.rawToken),
        case .object(let rawHeaders)? = response["headers"],
        case .string(let bodyFile)? = response["body_file"]
      else {
        throw SourcePipelineConformanceError.invalidSourceDefinition
      }
      let headers = try rawHeaders.map { name, headerValue in
        guard case .string(let stringValue) = headerValue else {
          throw SourcePipelineConformanceError.invalidSourceDefinition
        }
        return try HTTPHeader(name: name, value: stringValue)
      }
      let bodyURL = try safeChild(bodyFile, of: fixtureDirectory)
      let effectiveURL = try HTTPURL(origin + path)
      return SourceDispatchFixtureRoute(
        id: id,
        method: method,
        url: effectiveURL,
        response: try HTTPResponse(
          statusCode: status,
          effectiveURL: effectiveURL,
          headers: HTTPHeaders(headers),
          body: HTTPBody(Data(contentsOf: bodyURL))
        )
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

private struct SourceDispatchFixtureRoute: Sendable {
  let id: String
  let method: HTTPMethod
  let url: HTTPURL
  let response: HTTPResponse
}

private actor SourceDispatchFixtureTransport: HTTPTransport {
  private let routes: [String: SourceDispatchFixtureRoute]
  private var counts: [String: Int] = [:]

  init(routes: [SourceDispatchFixtureRoute]) {
    self.routes = Dictionary(
      uniqueKeysWithValues: routes.map {
        (Self.key(method: $0.method, url: $0.url), $0)
      }
    )
  }

  func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
    guard
      let route = routes[Self.key(method: request.method, url: request.url)]
    else {
      throw HTTPTransportFailure.invalidRequest
    }
    counts[route.id, default: 0] += 1
    return route.response
  }

  func requestCount(routeID: String) -> Int {
    counts[routeID, default: 0]
  }

  private static func key(method: HTTPMethod, url: HTTPURL) -> String {
    method.rawValue + "\u{0}" + url.absoluteString
  }
}
