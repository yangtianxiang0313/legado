import Foundation
import LegadoCore
import SourceRuntime

struct SourceResponseDecodingConformanceRun: Sendable {
  let artifact: JSONValue
  let requestPlan: JSONValue
}

enum SourceResponseDecodingConformanceRunner {
  static let fixtureID = "sl-source-transport-response-decoding-runtime-001"

  static func run(
    fixtureDirectory: URL
  ) throws -> SourceResponseDecodingConformanceRun {
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
      case .object(let transport)? = caseRoot["transport"],
      case .array(let responseDocuments)? = transport["responses"],
      case .object(let inputRoot) = inputDocument,
      case .array(let inputCases)? = inputRoot["cases"],
      case .object(let sourceRoot) = sourceDocument
    else {
      throw SourcePipelineConformanceError.invalidSourceDefinition
    }

    let routeList = try routes(
      responseDocuments,
      fixtureDirectory: fixtureDirectory
    )
    let routesByPath = Dictionary(
      uniqueKeysWithValues: routeList.map { ($0.path, $0) }
    )
    let headers = try sourceHeaders(sourceRoot)
    let policy = SourceRedirectPolicy()
    var routeCounts = Dictionary(
      uniqueKeysWithValues: routeList.map { ($0.id, 0) }
    )
    var requestPlans: [JSONValue] = []
    var cases: [JSONValue] = []

    for value in inputCases {
      guard
        case .object(let inputCase) = value,
        case .string(let id)? = inputCase["id"],
        inputCase["operation"] == .string("response_decoding"),
        case .object(let request)? = inputCase["request"],
        request["method"] == .string("GET"),
        case .string(let target)? = request["target"],
        target.hasPrefix("/")
      else {
        throw SourcePipelineConformanceError.invalidSourceDefinition
      }
      let url = try HTTPURL(origin + target)
      let requestHeaders = HTTPHeaders(
        try headers.map {
          try HTTPHeader(name: $0.name, value: $0.value)
        }
      )
      requestPlans.append(
        requestPlanValue(url: url, headers: requestHeaders)
      )

      do {
        let response = try followedResponse(
          initialPath: target,
          origin: origin,
          routes: routesByPath,
          policy: policy,
          counts: &routeCounts
        )
        let normalized = try SourceStringResponseNormalizer.normalize(response)
        cases.append(
          .object([
            "id": .string(id),
            "operation": .string("response_decoding"),
            "result": .object([
              "body": .string(normalized.body),
              "final_url": .string(normalized.finalURL.absoluteString),
              "is_successful": .bool((200...299).contains(response.statusCode)),
              "status_code": .number(JSONNumber(Int64(response.statusCode))),
            ]),
            "issue": .null,
          ])
        )
      } catch SourceStringResponseError.tooManyRedirects {
        cases.append(
          .object([
            "id": .string(id),
            "operation": .string("response_decoding"),
            "result": .null,
            "issue": .object([
              "code": .string("rule_failed"),
              "stage": .string("field_evaluation"),
            ]),
          ])
        )
      }
    }

    let plans = JSONValue.array(requestPlans)
    let artifact = JSONValue.object([
      "schema_version": .number(JSONNumber(1)),
      "fixture_id": .string(fixtureID),
      "engine": .object([
        "platform": .string("ios"),
        "revision": .string("conformance-source-runtime-v2"),
        "compatibility_profile": .string("android-legado-v1"),
      ]),
      "request_plan": plans,
      "decode": .null,
      "stages": .array([]),
      "result": .object([
        "type": .string("source_pipeline"),
        "value": .object([
          "portable_known_projection": .object([
            "cases": .array(cases)
          ]),
          "source_lab_observation": .object([
            "route_request_counts": .array(
              routeList.map { route in
                .object([
                  "request_count": .number(
                    JSONNumber(Int64(routeCounts[route.id, default: 0]))
                  ),
                  "route_id": .string(route.id),
                ])
              }
            )
          ]),
        ]),
      ]),
      "issues": .array([]),
    ])
    return SourceResponseDecodingConformanceRun(
      artifact: artifact,
      requestPlan: plans
    )
  }

  private static func followedResponse(
    initialPath: String,
    origin: String,
    routes: [String: ResponseDecodingRoute],
    policy: SourceRedirectPolicy,
    counts: inout [String: Int]
  ) throws -> HTTPResponse {
    var path = initialPath
    var followUpCount = 0
    while true {
      guard let route = routes[path] else {
        throw SourcePipelineConformanceError.inputRouteMismatch
      }
      counts[route.id, default: 0] += 1
      if
        (300...399).contains(route.statusCode),
        let location = route.location
      {
        followUpCount += 1
        try policy.validate(followUpCount: followUpCount)
        guard location.hasPrefix("/") else {
          throw SourcePipelineConformanceError.inputRouteMismatch
        }
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

  private static func requestPlanValue(
    url: HTTPURL,
    headers: HTTPHeaders
  ) -> JSONValue {
    .object([
      "method": .string("GET"),
      "url": .string(url.absoluteString),
      "headers": .array(
        headers.canonicalFields.map {
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

  private static func routes(
    _ values: [JSONValue],
    fixtureDirectory: URL
  ) throws -> [ResponseDecodingRoute] {
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
      let bodyURL = try safeChild(bodyFile, of: fixtureDirectory)
      let rawBody = try Data(contentsOf: bodyURL)
      let body: Data
      if bodyFile.hasSuffix(".base64") {
        guard let decoded = Data(
          base64Encoded: rawBody,
          options: [.ignoreUnknownCharacters]
        ) else {
          throw SourcePipelineConformanceError.invalidSourceDefinition
        }
        body = decoded
      } else {
        body = rawBody
      }
      return ResponseDecodingRoute(
        id: id,
        path: path,
        statusCode: statusCode,
        headers: HTTPHeaders(headers),
        body: body,
        location: location
      )
    }
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

private struct ResponseDecodingRoute: Sendable {
  let id: String
  let path: String
  let statusCode: Int
  let headers: HTTPHeaders
  let body: Data
  let location: String?
}
