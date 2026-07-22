import SourceRuntime

public enum FixtureTransportError: String, Error, Codable, Equatable, Sendable {
  case unexpectedRequest = "unexpected_request"
  case requestLimitExceeded = "request_limit_exceeded"
  case requestBodyTooLarge = "request_body_too_large"
}

public actor FixtureTransport: HTTPTransport {
  private let routes: [FixtureRoute]
  private let limits: FixtureLimits
  private var requests: [HTTPRequestEnvelope] = []

  public init(fixture: LoadedFixture) {
    self.routes = fixture.routes
    self.limits = fixture.definition.limits
  }

  public func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
    try Task.checkCancellation()
    guard requests.count < limits.maxRequests else {
      throw FixtureTransportError.requestLimitExceeded
    }
    guard (request.body?.bytes.count ?? 0) <= limits.maxRequestBodyBytes else {
      throw FixtureTransportError.requestBodyTooLarge
    }
    requests.append(HTTPRequestEnvelope(request: request))
    guard
      let route = routes.first(where: {
        $0.match.method == request.method && $0.match.url == request.url
      })
    else {
      throw FixtureTransportError.unexpectedRequest
    }
    return route.response
  }

  public func recordedRequestPlan() -> [HTTPRequestEnvelope] {
    requests
  }
}
