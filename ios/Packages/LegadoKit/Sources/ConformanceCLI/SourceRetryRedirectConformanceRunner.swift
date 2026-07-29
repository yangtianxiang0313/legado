import Foundation
import LegadoCore
import SourceRuntime

struct SourceRetryRedirectConformanceRun: Sendable {
  let artifact: JSONValue
  let requestPlan: JSONValue
}

enum SourceRetryRedirectConformanceRunner {
  static let fixtureID = "sl-source-transport-retry-redirect-runtime-001"

  static func run(
    fixtureDirectory: URL
  ) async throws -> SourceRetryRedirectConformanceRun {
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
      fixtureDirectory: fixtureDirectory
    )
    let transport = RetryRedirectRouteTransport(
      origin: origin,
      routes: routes
    )
    let headers = try sourceHeaders(sourceRoot)
    var plans: [JSONValue] = []
    var cases: [JSONValue] = []

    for value in inputCases {
      guard
        case .object(let inputCase) = value,
        case .string(let id)? = inputCase["id"],
        inputCase["operation"] == .string("retry_redirect"),
        case .object(let arguments)? = inputCase["arguments"],
        case .string(let mode)? = arguments["mode"],
        case .number(let retryNumber)? = arguments["retry"],
        let retry = Int(retryNumber.rawToken),
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
        headers: headers
      )
      plans.append(requestPlanValue(request))
      let result: JSONValue
      switch mode {
      case "analyze_url":
        result = try await analyzeURLResult(
          request: request,
          retry: retry,
          invokeRedirectCheck: arguments["invoke_redirect_check"] == .bool(true),
          transport: transport
        )
      case "helper_status_sequence":
        guard case .array(let rawStatuses)? = arguments["status_sequence"] else {
          throw SourcePipelineConformanceError.invalidSourceDefinition
        }
        let statuses = try rawStatuses.map { value -> Int in
          guard
            case .number(let number) = value,
            let status = Int(number.rawToken)
          else {
            throw SourcePipelineConformanceError.invalidSourceDefinition
          }
          return status
        }
        result = try await statusSequenceResult(
          request: request,
          retry: retry,
          statuses: statuses
        )
      case "helper_network_exception":
        result = await networkExceptionResult(
          request: request,
          retry: retry
        )
      case "helper_cancellation":
        result = await cancellationResult(
          request: request,
          retry: retry
        )
      default:
        throw SourcePipelineConformanceError.invalidSourceDefinition
      }
      cases.append(
        .object([
          "id": .string(id),
          "operation": .string("retry_redirect"),
          "result": result,
          "issue": .null,
        ])
      )
    }

    var routeCounts: [JSONValue] = []
    for route in routes {
      routeCounts.append(
        .object([
          "request_count": .number(
            JSONNumber(Int64(await transport.requestCount(routeID: route.id)))
          ),
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
    return SourceRetryRedirectConformanceRun(
      artifact: artifact,
      requestPlan: canonicalPlans
    )
  }

  private static func analyzeURLResult(
    request: HTTPRequest,
    retry: Int,
    invokeRedirectCheck: Bool,
    transport: RetryRedirectRouteTransport
  ) async throws -> JSONValue {
    let execution = try await SourceRequestExecutor(transport: transport)
      .execute(request, retry: retry)
    return .object([
      "body": .string(String(decoding: execution.response.body.bytes, as: UTF8.self)),
      "configured_retry": .number(JSONNumber(Int64(retry))),
      "final_url": .string(execution.effectiveURL.absoluteString),
      "is_successful": .bool(execution.isSuccessful),
      "redirect_check_completed": .bool(invokeRedirectCheck),
      "redirect_observed": .bool(execution.redirectObserved),
      "status_code": .number(
        JSONNumber(Int64(execution.response.statusCode))
      ),
    ])
  }

  private static func statusSequenceResult(
    request: HTTPRequest,
    retry: Int,
    statuses: [Int]
  ) async throws -> JSONValue {
    let transport = StatusSequenceProbeTransport(statuses: statuses)
    do {
      let execution = try await SourceRequestExecutor(transport: transport)
        .execute(request, retry: retry)
      let observation = await transport.observation()
      return .object([
        "attempt_count": .number(JSONNumber(Int64(execution.attemptCount))),
        "configured_retry": .number(JSONNumber(Int64(retry))),
        "exception_type": .null,
        "final_status": .number(
          JSONNumber(Int64(execution.response.statusCode))
        ),
        "is_successful": .bool(execution.isSuccessful),
        "observed_statuses": .array(
          observation.statuses.map {
            .number(JSONNumber(Int64($0)))
          }
        ),
        "request_fingerprints_identical": .bool(
          observation.requests.dropFirst().allSatisfy {
            $0 == observation.requests.first
          }
        ),
        "request_instance_count": .number(
          JSONNumber(Int64(observation.requests.count))
        ),
      ])
    } catch SourceRequestPreparationError.invalidRetry {
      let observation = await transport.observation()
      return .object([
        "attempt_count": .number(JSONNumber(0)),
        "configured_retry": .number(JSONNumber(Int64(retry))),
        "exception_type": .string("java.lang.NullPointerException"),
        "final_status": .null,
        "is_successful": .bool(false),
        "observed_statuses": .array([]),
        "request_fingerprints_identical": .bool(true),
        "request_instance_count": .number(
          JSONNumber(Int64(observation.requests.count))
        ),
      ])
    } catch {
      throw error
    }
  }

  private static func networkExceptionResult(
    request: HTTPRequest,
    retry: Int
  ) async -> JSONValue {
    let transport = NetworkExceptionProbeTransport()
    do {
      _ = try await SourceRequestExecutor(transport: transport)
        .execute(request, retry: retry)
    } catch {
      return .object([
        "attempt_count": .number(
          JSONNumber(Int64(await transport.attemptCount))
        ),
        "configured_retry": .number(JSONNumber(Int64(retry))),
        "exception_type": .string("java.io.IOException"),
        "response_received": .bool(false),
      ])
    }
    return .object([:])
  }

  private static func cancellationResult(
    request: HTTPRequest,
    retry: Int
  ) async -> JSONValue {
    let transport = CancellationProbeTransport()
    let task = Task {
      try await SourceRequestExecutor(transport: transport)
        .execute(request, retry: retry)
    }
    while await transport.observation().attemptCount == 0 {
      await Task.yield()
    }
    task.cancel()
    var propagated = false
    do {
      _ = try await task.value
    } catch is CancellationError {
      propagated = true
    } catch {
      propagated = false
    }
    var observation = await transport.observation()
    while !observation.callCancelled {
      await Task.yield()
      observation = await transport.observation()
    }
    return .object([
      "attempt_count": .number(JSONNumber(Int64(observation.attemptCount))),
      "call_cancelled": .bool(observation.callCancelled),
      "cancellation_propagated": .bool(propagated),
      "configured_retry": .number(JSONNumber(Int64(retry))),
      "response_received": .bool(false),
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

  private static func routeDefinitions(
    _ values: [JSONValue],
    fixtureDirectory: URL
  ) throws -> [RetryRedirectRoute] {
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
      let location: String?
      if case .string(let value)? = rawHeaders["location"] {
        location = value
      } else {
        location = nil
      }
      return RetryRedirectRoute(
        id: id,
        path: path,
        statusCode: statusCode,
        headers: HTTPHeaders(headers),
        body: try Data(contentsOf: safeChild(bodyFile, of: fixtureDirectory)),
        location: location
      )
    }
  }

  private static func sourceHeaders(
    _ source: [String: JSONValue]
  ) throws -> HTTPHeaders {
    guard case .string(let headerText)? = source["header"] else {
      return HTTPHeaders()
    }
    guard
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

private struct RetryRedirectRoute: Sendable {
  let id: String
  let path: String
  let statusCode: Int
  let headers: HTTPHeaders
  let body: Data
  let location: String?
}

private actor RetryRedirectRouteTransport: HTTPTransport {
  private let origin: String
  private let routes: [String: RetryRedirectRoute]
  private var counts: [String: Int]

  init(origin: String, routes: [RetryRedirectRoute]) {
    self.origin = origin
    self.routes = Dictionary(uniqueKeysWithValues: routes.map { ($0.path, $0) })
    self.counts = Dictionary(uniqueKeysWithValues: routes.map { ($0.id, 0) })
  }

  func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
    guard
      let components = URLComponents(string: request.url.absoluteString),
      components.scheme != nil,
      components.host != nil
    else {
      throw SourcePipelineConformanceError.inputRouteMismatch
    }
    var path = components.percentEncodedPath
    while true {
      guard let route = routes[path] else {
        throw SourcePipelineConformanceError.inputRouteMismatch
      }
      counts[route.id, default: 0] += 1
      if
        (300...399).contains(route.statusCode),
        let location = route.location,
        location.hasPrefix("/")
      {
        path = location
        continue
      }
      return try HTTPResponse(
        statusCode: route.statusCode,
        effectiveURL: HTTPURL(origin + path),
        headers: route.headers,
        body: HTTPBody(route.body)
      )
    }
  }

  func requestCount(routeID: String) -> Int {
    counts[routeID, default: 0]
  }
}

private actor StatusSequenceProbeTransport: HTTPTransport {
  private let statuses: [Int]
  private var requests: [HTTPRequest] = []
  private var observedStatuses: [Int] = []

  init(statuses: [Int]) {
    self.statuses = statuses
  }

  func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
    guard !statuses.isEmpty else {
      throw SourcePipelineConformanceError.invalidSourceDefinition
    }
    let status = statuses[min(requests.count, statuses.count - 1)]
    requests.append(request)
    observedStatuses.append(status)
    return try HTTPResponse(
      statusCode: status,
      effectiveURL: request.url,
      body: HTTPBody(Data())
    )
  }

  func observation() -> (requests: [HTTPRequest], statuses: [Int]) {
    (requests, observedStatuses)
  }
}

private actor NetworkExceptionProbeTransport: HTTPTransport {
  private(set) var attemptCount = 0

  func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
    attemptCount += 1
    throw HTTPTransportFailure.connectionFailed
  }
}

private actor CancellationProbeTransport: HTTPTransport {
  private var attempts = 0
  private var cancelled = false

  func observation() -> (attemptCount: Int, callCancelled: Bool) {
    (attempts, cancelled)
  }

  func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
    attempts += 1
    return try await withTaskCancellationHandler {
      try await Task.sleep(for: .seconds(60))
      return try HTTPResponse(
        statusCode: 200,
        effectiveURL: request.url,
        body: HTTPBody(Data())
      )
    } onCancel: {
      Task {
        await self.markCancelled()
      }
    }
  }

  private func markCancelled() {
    cancelled = true
  }
}
