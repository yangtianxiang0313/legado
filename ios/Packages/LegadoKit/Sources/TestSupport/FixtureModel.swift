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
  case rawResponse = "raw_response"
  case requestOptions = "request_options"
  case fieldEncoding = "field_encoding"
  case urlTemplateCompilation = "url_template_compilation"
  case rateLimitState = "rate_limit_state"
  case transportDispatch = "transport_dispatch"
  case rule
}

public enum FixtureTransportMode: String, Codable, Sendable {
  case offline
  case fixtureAndLoopback = "fixture_and_loopback"
}

public struct FixtureDefinition: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let kind: String?
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
    case kind
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
  public let externalNetwork: String?
  public let responses: [FixtureRouteDefinition]

  enum CodingKeys: String, CodingKey {
    case mode
    case externalNetwork = "external_network"
    case responses
  }
}

public struct FixtureRouteDefinition: Codable, Equatable, Sendable {
  public let id: String
  public let match: FixtureRequestMatch
  public let respond: FixtureResponseDefinition
}

public struct FixtureRequestMatch: Codable, Equatable, Sendable {
  public let method: HTTPMethod
  public let url: HTTPURL?
  public let path: String?
  public let query: [String: String]?

  enum CodingKeys: String, CodingKey {
    case method
    case url
    case path
    case query
  }
}

public struct FixtureResponseDefinition: Codable, Equatable, Sendable {
  public let status: Int
  public let effectiveURL: HTTPURL?
  public let headers: HTTPHeaders
  public let bodyFile: String

  enum CodingKeys: String, CodingKey {
    case status
    case effectiveURL = "effective_url"
    case headers
    case bodyFile = "body_file"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.status = try container.decode(Int.self, forKey: .status)
    self.effectiveURL = try container.decodeIfPresent(HTTPURL.self, forKey: .effectiveURL)
    self.bodyFile = try container.decode(String.self, forKey: .bodyFile)
    if let headers = try? container.decode(HTTPHeaders.self, forKey: .headers) {
      self.headers = headers
    } else {
      let dictionary = try container.decode([String: String].self, forKey: .headers)
      self.headers = HTTPHeaders(
        try dictionary.sorted {
          let lhs = $0.key.lowercased()
          let rhs = $1.key.lowercased()
          return lhs == rhs ? $0.key < $1.key : lhs < rhs
        }.map {
          try HTTPHeader(name: $0.key, value: $0.value)
        }
      )
    }
  }
}

public struct FixtureDeterminism: Codable, Equatable, Sendable {
  public let clock: String
  public let timezone: String
  public let locale: String
  public let randomSeed: Int
  public let networkAllowed: Bool
  public let logicalOrigin: HTTPURL?

  enum CodingKeys: String, CodingKey {
    case clock
    case timezone
    case locale
    case randomSeed = "random_seed"
    case networkAllowed = "network_allowed"
    case logicalOrigin = "logical_origin"
  }
}

public struct FixtureLimits: Codable, Equatable, Sendable {
  public let timeoutMilliseconds: Int
  public let maxResponseBytes: Int
  public let maxRequestBodyBytes: Int
  public let maxRequests: Int
  public let maxConcurrency: Int?

  enum CodingKeys: String, CodingKey {
    case timeoutMilliseconds = "timeout_ms"
    case maxResponseBytes = "max_response_bytes"
    case maxRequestBodyBytes = "max_request_body_bytes"
    case maxRequests = "max_requests"
    case maxConcurrency = "max_concurrency"
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

public struct SourceLabInputDefinition: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let cases: [SourceLabInputCase]

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case cases
  }
}

public struct SourceLabInputCase: Codable, Equatable, Sendable {
  public let id: String
  public let operation: FixtureOperation
  public let request: SourceLabRequestDefinition
}

public struct SourceLabRequestDefinition: Codable, Equatable, Sendable {
  public let method: HTTPMethod
  public let target: String
}

public struct FixtureRequestCase: Equatable, Sendable {
  public let id: String
  public let operation: FixtureOperation
  public let request: HTTPRequest

  public init(id: String, operation: FixtureOperation, request: HTTPRequest) {
    self.id = id
    self.operation = operation
    self.request = request
  }
}

public struct FixtureRoute: Equatable, Sendable {
  public let id: String
  public let target: FixtureRequestTarget
  public let statusCode: Int
  public let effectiveURL: HTTPURL?
  public let headers: HTTPHeaders
  public let body: HTTPBody

  public init(
    id: String,
    target: FixtureRequestTarget,
    statusCode: Int,
    effectiveURL: HTTPURL?,
    headers: HTTPHeaders,
    body: HTTPBody
  ) {
    self.id = id
    self.target = target
    self.statusCode = statusCode
    self.effectiveURL = effectiveURL
    self.headers = headers
    self.body = body
  }
}

public struct LoadedFixture: Sendable {
  public let definition: FixtureDefinition
  public let sourceTemplateData: Data
  public let sourceData: Data
  public let logicalOrigin: FixtureOrigin
  public let request: HTTPRequest
  public let requestCases: [FixtureRequestCase]
  public let routes: [FixtureRoute]

  init(
    definition: FixtureDefinition,
    sourceTemplateData: Data,
    sourceData: Data,
    logicalOrigin: FixtureOrigin,
    requestCases: [FixtureRequestCase],
    routes: [FixtureRoute]
  ) throws {
    guard let request = requestCases.first else {
      throw FixtureLoadingError.invalidDefinition
    }
    self.definition = definition
    self.sourceTemplateData = sourceTemplateData
    self.sourceData = sourceData
    self.logicalOrigin = logicalOrigin
    self.requestCases = requestCases
    self.request = request.request
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

  public func request(replacingBody data: Data) -> HTTPRequest {
    HTTPRequest(
      method: request.method,
      url: request.url,
      headers: request.headers,
      body: HTTPBody(data),
      timeout: request.timeout
    )
  }
}

public enum LoadedConformanceFixture: Sendable {
  case sourceRoundTrip(LoadedSourceRoundTripFixture)
  case transport(LoadedFixture)

  public var definition: FixtureDefinition {
    switch self {
    case .sourceRoundTrip(let fixture):
      fixture.definition
    case .transport(let fixture):
      fixture.definition
    }
  }
}

public struct LoadedSourceRoundTripFixture: Sendable {
  public let definition: FixtureDefinition
  public let sourceData: Data
}
