import Foundation
import SourceRuntime

public enum FixtureOperation: String, Codable, Sendable {
  case sourceRoundTrip = "source_round_trip"
  case sourceLabSite = "source_lab_site"
  case search
  case explore
  case bookInfo = "book_info"
  case chapters
  case content
  case rule
}

public enum FixtureTransportMode: String, Codable, Sendable {
  case offline
  case fixtureAndLoopback = "fixture_and_loopback"
}

public struct FixtureDefinition: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let id: String
  public let operation: FixtureOperation
  public let capabilities: [String]
  public let compatibilityProfile: String
  public let source: String
  public let input: String
  public let transport: FixtureTransportDefinition
  public let determinism: FixtureDeterminism
  public let limits: FixtureLimits

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case id
    case operation
    case capabilities
    case compatibilityProfile = "compatibility_profile"
    case source
    case input
    case transport
    case determinism
    case limits
  }
}

public struct FixtureTransportDefinition: Codable, Equatable, Sendable {
  public let mode: FixtureTransportMode
  public let responses: [FixtureRouteDefinition]
}

public struct FixtureRouteDefinition: Codable, Equatable, Sendable {
  public let id: String
  public let match: FixtureRequestMatch
  public let respond: FixtureResponseDefinition
}

public struct FixtureRequestMatch: Codable, Equatable, Sendable {
  public let method: HTTPMethod
  public let url: HTTPURL
}

public struct FixtureResponseDefinition: Codable, Equatable, Sendable {
  public let status: Int
  public let effectiveURL: HTTPURL
  public let headers: HTTPHeaders
  public let bodyFile: String

  enum CodingKeys: String, CodingKey {
    case status
    case effectiveURL = "effective_url"
    case headers
    case bodyFile = "body_file"
  }
}

public struct FixtureDeterminism: Codable, Equatable, Sendable {
  public let clock: String
  public let timezone: String
  public let locale: String
  public let randomSeed: Int
  public let networkAllowed: Bool

  enum CodingKeys: String, CodingKey {
    case clock
    case timezone
    case locale
    case randomSeed = "random_seed"
    case networkAllowed = "network_allowed"
  }
}

public struct FixtureLimits: Codable, Equatable, Sendable {
  public let timeoutMilliseconds: Int
  public let maxResponseBytes: Int
  public let maxRequestBodyBytes: Int
  public let maxRequests: Int

  enum CodingKeys: String, CodingKey {
    case timeoutMilliseconds = "timeout_ms"
    case maxResponseBytes = "max_response_bytes"
    case maxRequestBodyBytes = "max_request_body_bytes"
    case maxRequests = "max_requests"
  }
}

public struct FixtureInputDefinition: Codable, Equatable, Sendable {
  public let method: HTTPMethod
  public let url: HTTPURL
  public let headers: HTTPHeaders
  public let bodyFile: String?

  enum CodingKeys: String, CodingKey {
    case method
    case url
    case headers
    case bodyFile = "body_file"
  }
}

public struct FixtureRoute: Equatable, Sendable {
  public let id: String
  public let match: FixtureRequestMatch
  public let response: HTTPResponse

  public init(id: String, match: FixtureRequestMatch, response: HTTPResponse) {
    self.id = id
    self.match = match
    self.response = response
  }
}

public struct LoadedFixture: Sendable {
  public let definition: FixtureDefinition
  public let sourceData: Data
  public let request: HTTPRequest
  public let routes: [FixtureRoute]

  public init(
    definition: FixtureDefinition,
    sourceData: Data,
    request: HTTPRequest,
    routes: [FixtureRoute]
  ) {
    self.definition = definition
    self.sourceData = sourceData
    self.request = request
    self.routes = routes
  }

  public func request(replacingURL absoluteString: String) throws -> HTTPRequest {
    HTTPRequest(
      method: request.method,
      url: try HTTPURL(absoluteString),
      headers: request.headers,
      body: request.body,
      timeout: request.timeout
    )
  }
}
