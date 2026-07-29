import Foundation
import LegadoCore
import LibraryDomain
import ReaderCore
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

public enum ReaderBookmarkFixtureProjectionError: Error, Sendable {
  case invalidFixture
}

public struct ReaderBookmarkFixtureProjectionRun: Sendable {
  public let artifact: JSONValue
  public let requestPlan: JSONValue

  public init(artifact: JSONValue, requestPlan: JSONValue) {
    self.artifact = artifact
    self.requestPlan = requestPlan
  }
}

public enum ReaderBookmarkFixtureProjection {
  public static let fixtureID =
    "rl-reader-bookmark-search-runtime-risk-001"

  public static func run(
    caseData: Data,
    inputData: Data
  ) throws -> ReaderBookmarkFixtureProjectionRun {
    let caseDocument: JSONValue
    let inputDocument: JSONValue
    do {
      caseDocument = try JSONValueCodec.decode(caseData)
      inputDocument = try JSONValueCodec.decode(inputData)
    } catch {
      throw ReaderBookmarkFixtureProjectionError.invalidFixture
    }
    guard
      case .object(let caseRoot) = caseDocument,
      caseRoot["id"] == .string(fixtureID),
      caseRoot["kind"] == .string("android_runtime_scenario"),
      caseRoot["operation"] == .string("android_runtime"),
      case .object(let inputRoot) = inputDocument,
      case .array(let inputCases)? = inputRoot["cases"]
    else {
      throw ReaderBookmarkFixtureProjectionError.invalidFixture
    }

    var plans: [JSONValue] = []
    var cases: [JSONValue] = []
    var identifiers: Set<String> = []
    for value in inputCases {
      guard
        case .object(let inputCase) = value,
        case .string(let id)? = inputCase["id"],
        identifiers.insert(id).inserted,
        case .string(let operation)? = inputCase["operation"],
        case .object(let arguments)? = inputCase["arguments"]
      else {
        throw ReaderBookmarkFixtureProjectionError.invalidFixture
      }
      plans.append(
        .object([
          "operation": .string(operation),
          "arguments": .object(arguments),
        ])
      )
      let result: JSONValue
      switch operation {
      case "bookmark_search":
        result = try search(arguments)
      case "bookmark_insert_conflict":
        result = try insertConflict(arguments)
      default:
        throw ReaderBookmarkFixtureProjectionError.invalidFixture
      }
      cases.append(
        .object([
          "id": .string(id),
          "operation": .string(operation),
          "result": result,
          "issue": .null,
        ])
      )
    }

    let requestPlan = JSONValue.array(plans)
    return ReaderBookmarkFixtureProjectionRun(
      artifact: .object([
        "schema_version": number(1),
        "fixture_id": .string(fixtureID),
        "engine": .object([
          "platform": .string("ios"),
          "revision": .string("reader-bookmark-compatibility-v1"),
          "compatibility_profile": .string("android-legado-v1"),
        ]),
        "request_plan": requestPlan,
        "decode": .null,
        "stages": .array([]),
        "result": .object([
          "type": .string("reader_runtime"),
          "value": .object([
            "portable_known_projection": .object([
              "cases": .array(cases)
            ])
          ]),
        ]),
        "issues": .array([]),
      ]),
      requestPlan: requestPlan
    )
  }

  private static func search(
    _ arguments: [String: JSONValue]
  ) throws -> JSONValue {
    guard
      case .string(let bookName)? = arguments["book_name"],
      case .string(let bookAuthor)? = arguments["book_author"],
      case .string(let key)? = arguments["key"]
    else {
      throw ReaderBookmarkFixtureProjectionError.invalidFixture
    }
    return rows(
      AndroidBookmarkCompatibility.search(
        try bookmarks(arguments),
        bookName: bookName,
        bookAuthor: bookAuthor,
        key: key
      )
    )
  }

  private static func insertConflict(
    _ arguments: [String: JSONValue]
  ) throws -> JSONValue {
    rows(
      AndroidBookmarkCompatibility.insertingReplacingByTime(
        try bookmarks(arguments)
      )
    )
  }

  private static func bookmarks(
    _ arguments: [String: JSONValue]
  ) throws -> [Bookmark] {
    guard case .array(let values)? = arguments["rows"] else {
      throw ReaderBookmarkFixtureProjectionError.invalidFixture
    }
    return try values.map { value in
      guard
        case .object(let row) = value,
        case .number(let time)? = row["time"],
        let timeValue = Int64(time.rawToken),
        case .string(let bookName)? = row["bookName"],
        case .string(let bookAuthor)? = row["bookAuthor"],
        case .number(let chapterIndex)? = row["chapterIndex"],
        let chapterIndexValue = Int(chapterIndex.rawToken),
        case .number(let chapterPosition)? = row["chapterPos"],
        let chapterPositionValue = Int(chapterPosition.rawToken),
        case .string(let chapterName)? = row["chapterName"],
        case .string(let bookText)? = row["bookText"],
        case .string(let content)? = row["content"]
      else {
        throw ReaderBookmarkFixtureProjectionError.invalidFixture
      }
      return Bookmark(
        time: timeValue,
        bookName: bookName,
        bookAuthor: bookAuthor,
        chapterIndex: chapterIndexValue,
        chapterPosition: chapterPositionValue,
        chapterName: chapterName,
        bookText: bookText,
        content: content
      )
    }
  }

  private static func rows(_ bookmarks: [Bookmark]) -> JSONValue {
    .object([
      "row_count": number(bookmarks.count),
      "rows": .array(
        bookmarks.map { bookmark in
          .object([
            "time": number(bookmark.time),
            "book_name": .string(bookmark.bookName),
            "book_author": .string(bookmark.bookAuthor),
            "chapter_index": number(bookmark.chapterIndex),
            "chapter_pos": number(bookmark.chapterPosition),
            "chapter_name": .string(bookmark.chapterName),
            "book_text": .string(bookmark.bookText),
            "content": .string(bookmark.content),
          ])
        }
      ),
    ])
  }

  private static func number(_ value: Int) -> JSONValue {
    .number(JSONNumber(Int64(value)))
  }

  private static func number(_ value: Int64) -> JSONValue {
    .number(JSONNumber(value))
  }
}
