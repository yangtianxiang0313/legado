import SourceRuntime

public enum FixtureTransportError: String, Error, Codable, Equatable, Sendable {
  case externalAuthority = "external_authority"
  case invalidTarget = "invalid_target"
  case invalidQuery = "invalid_query"
  case duplicateQuery = "duplicate_query"
  case unexpectedRequest = "unexpected_request"
  case requestLimitExceeded = "request_limit_exceeded"
  case requestBodyTooLarge = "request_body_too_large"
}

public actor FixtureTransport: HTTPTransport {
  private let routes: [FixtureRoute]
  private let limits: FixtureLimits
  private let mode: FixtureTransportMode
  private let logicalOrigin: FixtureOrigin
  private var requestCount = 0
  private var requests: [HTTPRequestEnvelope] = []

  public init(fixture: LoadedFixture) {
    self.routes = fixture.routes
    self.limits = fixture.definition.limits
    self.mode = fixture.definition.transport.mode
    self.logicalOrigin = fixture.logicalOrigin
  }

  public func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
    try Task.checkCancellation()
    if mode == .fixtureAndLoopback {
      return try executeSourceLab(request)
    }
    guard requestCount < limits.maxRequests else {
      throw FixtureTransportError.requestLimitExceeded
    }
    guard (request.body?.bytes.count ?? 0) <= limits.maxRequestBodyBytes else {
      throw FixtureTransportError.requestBodyTooLarge
    }
    requestCount += 1
    requests.append(HTTPRequestEnvelope(request: request))
    let target = try FixtureRequestTarget(method: request.method, url: request.url)
    guard let route = routes.first(where: { $0.target == target }) else {
      throw FixtureTransportError.unexpectedRequest
    }
    return try response(for: route, request: request)
  }

  public func recordedRequestPlan() -> [HTTPRequestEnvelope] {
    requests
  }

  private func executeSourceLab(_ request: HTTPRequest) throws -> HTTPResponse {
    try validateSourceLabAuthorityAndTarget(request.url)
    guard requestCount < limits.maxRequests else {
      throw FixtureTransportError.requestLimitExceeded
    }
    requestCount += 1
    requests.append(HTTPRequestEnvelope(request: request))
    guard (request.body?.bytes.count ?? 0) <= limits.maxRequestBodyBytes else {
      throw FixtureTransportError.requestBodyTooLarge
    }

    let target: FixtureRequestTarget
    do {
      target = try FixtureRequestTarget(
        method: request.method,
        sourceLabURL: request.url,
        origin: logicalOrigin
      )
    } catch FixtureTargetError.duplicateQuery {
      throw FixtureTransportError.duplicateQuery
    } catch FixtureTargetError.invalidQuery {
      throw FixtureTransportError.invalidQuery
    } catch {
      throw FixtureTransportError.invalidTarget
    }
    guard let route = routes.first(where: { $0.target == target }) else {
      throw FixtureTransportError.unexpectedRequest
    }
    return try response(for: route, request: request)
  }

  private func response(for route: FixtureRoute, request: HTTPRequest) throws -> HTTPResponse {
    try HTTPResponse(
      statusCode: route.statusCode,
      effectiveURL: route.effectiveURL ?? request.url,
      headers: route.headers,
      body: route.body
    )
  }

  private func validateSourceLabAuthorityAndTarget(_ url: HTTPURL) throws {
    let absoluteString = url.absoluteString
    let origin = logicalOrigin.absoluteString
    guard absoluteString.hasPrefix(origin) else {
      throw FixtureTransportError.externalAuthority
    }
    let rawTarget = absoluteString.dropFirst(origin.count)
    guard rawTarget.hasPrefix("/") else {
      throw FixtureTransportError.externalAuthority
    }
    guard !rawTarget.hasPrefix("//") else {
      throw FixtureTransportError.invalidTarget
    }
  }
}
