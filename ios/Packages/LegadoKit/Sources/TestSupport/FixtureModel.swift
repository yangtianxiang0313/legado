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

public enum ReaderReadRecordFixtureProjectionError: Error, Sendable {
  case invalidFixture
}

public struct ReaderReadRecordFixtureProjectionRun: Sendable {
  public let artifact: JSONValue
  public let requestPlan: JSONValue

  public init(artifact: JSONValue, requestPlan: JSONValue) {
    self.artifact = artifact
    self.requestPlan = requestPlan
  }
}

public enum ReaderReadRecordFixtureProjection {
  public static let fixtureID =
    "rl-reader-history-read-record-runtime-risk-001"

  public static func run(
    caseData: Data,
    inputData: Data
  ) throws -> ReaderReadRecordFixtureProjectionRun {
    let caseDocument: JSONValue
    let inputDocument: JSONValue
    do {
      caseDocument = try JSONValueCodec.decode(caseData)
      inputDocument = try JSONValueCodec.decode(inputData)
    } catch {
      throw ReaderReadRecordFixtureProjectionError.invalidFixture
    }
    guard
      case .object(let caseRoot) = caseDocument,
      caseRoot["id"] == .string(fixtureID),
      caseRoot["kind"] == .string("android_runtime_scenario"),
      caseRoot["operation"] == .string("android_runtime"),
      case .object(let inputRoot) = inputDocument,
      case .array(let inputCases)? = inputRoot["cases"]
    else {
      throw ReaderReadRecordFixtureProjectionError.invalidFixture
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
        throw ReaderReadRecordFixtureProjectionError.invalidFixture
      }
      plans.append(
        .object([
          "operation": .string(operation),
          "arguments": .object(arguments),
        ])
      )
      let result: JSONValue
      switch operation {
      case "read_record_query":
        result = try query(arguments)
      case "read_record_reset":
        result = try reset(arguments)
      case "read_record_session_write":
        result = try sessionWrite(arguments)
      case "read_record_pause_boundary":
        result = try pauseBoundary(arguments)
      case "read_record_disabled":
        result = try disabled(arguments)
      case "read_record_insert_conflict":
        result = try insertConflict(arguments)
      default:
        throw ReaderReadRecordFixtureProjectionError.invalidFixture
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
    return ReaderReadRecordFixtureProjectionRun(
      artifact: .object([
        "schema_version": number(1),
        "fixture_id": .string(fixtureID),
        "engine": .object([
          "platform": .string("ios"),
          "revision": .string("reader-read-record-compatibility-v1"),
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

  private static func query(
    _ arguments: [String: JSONValue]
  ) throws -> JSONValue {
    let rows = try records(arguments)
    guard
      case .string(let bookName)? = arguments["book_name"],
      case .array(let deviceValues)? = arguments["device_ids"]
    else {
      throw ReaderReadRecordFixtureProjectionError.invalidFixture
    }
    let deviceIDs = try deviceValues.map { value in
      guard case .string(let deviceID) = value else {
        throw ReaderReadRecordFixtureProjectionError.invalidFixture
      }
      return deviceID
    }
    return .object([
      "all_books_read_time": number(
        AndroidReadRecordCompatibility.aggregateReadTime(rows)
      ),
      "all_device_read_time": number(
        AndroidReadRecordCompatibility.aggregateReadTime(
          rows,
          bookName: bookName
        )
      ),
      "per_device": .array(
        deviceIDs.map { deviceID in
          .object([
            "device_id": .string(deviceID),
            "read_time": nullableNumber(
              AndroidReadRecordCompatibility.readTime(
                rows,
                deviceID: deviceID,
                bookName: bookName
              )
            ),
          ])
        }
      ),
    ])
  }

  private static func reset(
    _ arguments: [String: JSONValue]
  ) throws -> JSONValue {
    let rows = try records(arguments)
    let bookName = try requiredString("book_name", in: arguments)
    let aggregate = AndroidReadRecordCompatibility.aggregateReadTime(
      rows,
      bookName: bookName
    )
    let session = AndroidReadRecordCompatibility.resetSession(
      records: rows,
      bookName: bookName,
      readStartTimeMilliseconds: 0
    )
    return .object([
      "aggregate_before_reset": number(aggregate),
      "session_book_name": .string(session.bookName),
      "session_device_id": .string(session.deviceID),
      "session_read_time": number(session.readTime),
      "session_uses_all_device_total": .bool(
        session.readTime == aggregate
      ),
    ])
  }

  private static func sessionWrite(
    _ arguments: [String: JSONValue]
  ) throws -> JSONValue {
    let rows =
      AndroidReadRecordCompatibility
      .insertingReplacingByCompositeKey(try records(arguments))
    let bookName = try requiredString("book_name", in: arguments)
    let aggregateBefore =
      AndroidReadRecordCompatibility.aggregateReadTime(
        rows,
        bookName: bookName
      )
    let foreignRows = rows.filter {
      $0.bookName == bookName && !$0.deviceID.isEmpty
    }
    let foreignTotal = foreignRows.reduce(Int64(0)) {
      $0 &+ $1.readTime
    }
    let session = AndroidReadRecordCompatibility.resetSession(
      records: rows,
      bookName: bookName,
      readStartTimeMilliseconds: 0
    )
    let update = AndroidReadRecordCompatibility.updateReadTime(
      session: session,
      nowMilliseconds: 0,
      recordingEnabled: true
    )
    guard let inserted = update.recordToPersist else {
      throw ReaderReadRecordFixtureProjectionError.invalidFixture
    }
    let after =
      AndroidReadRecordCompatibility
      .insertingReplacingByCompositeKey(rows + [inserted])
    let aggregateAfter =
      AndroidReadRecordCompatibility.aggregateReadTime(
        after,
        bookName: bookName
      )
    let foreignAfter = after.filter {
      $0.bookName == bookName && !$0.deviceID.isEmpty
    }
    return .object([
      "aggregate_after_minus_empty_row": number(
        aggregateAfter &- inserted.readTime
      ),
      "aggregate_before": number(aggregateBefore),
      "foreign_device_total": number(foreignTotal),
      "foreign_rows_preserved": .bool(foreignRows == foreignAfter),
      "foreign_time_counted_twice": .bool(
        aggregateAfter == (foreignTotal &+ inserted.readTime)
          && inserted.readTime >= aggregateBefore
      ),
      "inserted_at_least_aggregate_before": .bool(
        inserted.readTime >= aggregateBefore
      ),
      "inserted_device_id": .string(inserted.deviceID),
      "session_delta_nonnegative": .bool(
        update.session.readTime >= session.readTime
      ),
    ])
  }

  private static func pauseBoundary(
    _ arguments: [String: JSONValue]
  ) throws -> JSONValue {
    let rows =
      AndroidReadRecordCompatibility
      .insertingReplacingByCompositeKey(try records(arguments))
    let bookName = try requiredString("book_name", in: arguments)
    let readStartTime = try requiredInt64(
      "read_start_time",
      in: arguments
    )
    let session = AndroidReadRecordCompatibility.resetSession(
      records: rows,
      bookName: bookName,
      readStartTimeMilliseconds: readStartTime
    )
    let saved = AndroidReadRecordCompatibility.saveReadWithoutSettling(
      session: session
    )
    return .object([
      "database_rows_unchanged": .bool(true),
      "persisted_empty_device_read_time": nullableNumber(
        AndroidReadRecordCompatibility.readTime(
          rows,
          deviceID: "",
          bookName: bookName
        )
      ),
      "read_start_time_unchanged": .bool(
        saved.readStartTimeMilliseconds == readStartTime
      ),
      "save_read_settled_session_time": .bool(
        saved.readTime != session.readTime
      ),
      "session_in_memory_read_time": number(saved.readTime),
    ])
  }

  private static func disabled(
    _ arguments: [String: JSONValue]
  ) throws -> JSONValue {
    let rows =
      AndroidReadRecordCompatibility
      .insertingReplacingByCompositeKey(try records(arguments))
    let bookName = try requiredString("book_name", in: arguments)
    let readStartTime = try requiredInt64(
      "read_start_time",
      in: arguments
    )
    let session = AndroidReadRecordCompatibility.resetSession(
      records: rows,
      bookName: bookName,
      readStartTimeMilliseconds: readStartTime
    )
    let update = AndroidReadRecordCompatibility.updateReadTime(
      session: session,
      nowMilliseconds: readStartTime &+ 10_000,
      recordingEnabled: false
    )
    return .object([
      "persisted_row_count": number(rows.count),
      "read_start_time_unchanged": .bool(
        update.session.readStartTimeMilliseconds == readStartTime
      ),
      "session_read_time": number(update.session.readTime),
    ])
  }

  private static func insertConflict(
    _ arguments: [String: JSONValue]
  ) throws -> JSONValue {
    let rows =
      AndroidReadRecordCompatibility
      .insertingReplacingByCompositeKey(try records(arguments))
    let bookName = try requiredString("book_name", in: arguments)
    return .object([
      "aggregate_read_time": number(
        AndroidReadRecordCompatibility.aggregateReadTime(
          rows,
          bookName: bookName
        )
      ),
      "row_count": number(rows.count),
      "rows": .array(
        rows.map { row in
          .object([
            "book_name": .string(row.bookName),
            "device_id": .string(row.deviceID),
            "last_read": number(row.lastRead),
            "read_time": number(row.readTime),
          ])
        }
      ),
    ])
  }

  private static func records(
    _ arguments: [String: JSONValue]
  ) throws -> [ReadRecord] {
    guard case .array(let values)? = arguments["rows"] else {
      throw ReaderReadRecordFixtureProjectionError.invalidFixture
    }
    return try values.map { value in
      guard
        case .object(let row) = value,
        case .string(let deviceID)? = row["deviceId"],
        case .string(let bookName)? = row["bookName"],
        case .number(let readTime)? = row["readTime"],
        let readTimeValue = Int64(readTime.rawToken),
        case .number(let lastRead)? = row["lastRead"],
        let lastReadValue = Int64(lastRead.rawToken)
      else {
        throw ReaderReadRecordFixtureProjectionError.invalidFixture
      }
      return ReadRecord(
        deviceID: deviceID,
        bookName: bookName,
        readTime: readTimeValue,
        lastRead: lastReadValue
      )
    }
  }

  private static func requiredString(
    _ key: String,
    in arguments: [String: JSONValue]
  ) throws -> String {
    guard case .string(let value)? = arguments[key] else {
      throw ReaderReadRecordFixtureProjectionError.invalidFixture
    }
    return value
  }

  private static func requiredInt64(
    _ key: String,
    in arguments: [String: JSONValue]
  ) throws -> Int64 {
    guard
      case .number(let number)? = arguments[key],
      let value = Int64(number.rawToken)
    else {
      throw ReaderReadRecordFixtureProjectionError.invalidFixture
    }
    return value
  }

  private static func nullableNumber(_ value: Int64?) -> JSONValue {
    value.map(number) ?? .null
  }

  private static func number(_ value: Int) -> JSONValue {
    .number(JSONNumber(Int64(value)))
  }

  private static func number(_ value: Int64) -> JSONValue {
    .number(JSONNumber(value))
  }
}

public enum ReaderProgressFixtureProjectionError: Error, Sendable {
  case invalidFixture
}

public struct ReaderProgressFixtureProjectionRun: Sendable {
  public let artifact: JSONValue
  public let requestPlan: JSONValue

  public init(artifact: JSONValue, requestPlan: JSONValue) {
    self.artifact = artifact
    self.requestPlan = requestPlan
  }
}

public enum ReaderProgressFixtureProjection {
  public static let fixtureID =
    "rl-reader-progress-layout-save-runtime-001"

  public static func run(
    caseData: Data,
    inputData: Data
  ) throws -> ReaderProgressFixtureProjectionRun {
    let caseDocument: JSONValue
    let inputDocument: JSONValue
    do {
      caseDocument = try JSONValueCodec.decode(caseData)
      inputDocument = try JSONValueCodec.decode(inputData)
    } catch {
      throw ReaderProgressFixtureProjectionError.invalidFixture
    }
    guard
      case .object(let caseRoot) = caseDocument,
      caseRoot["id"] == .string(fixtureID),
      caseRoot["kind"] == .string("android_runtime_scenario"),
      caseRoot["operation"] == .string("android_runtime"),
      case .object(let inputRoot) = inputDocument,
      case .array(let inputCases)? = inputRoot["cases"]
    else {
      throw ReaderProgressFixtureProjectionError.invalidFixture
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
        throw ReaderProgressFixtureProjectionError.invalidFixture
      }
      plans.append(
        .object([
          "operation": .string(operation),
          "arguments": .object(arguments),
        ])
      )
      let result: JSONValue
      switch operation {
      case "layout_set_page_index":
        result = try setPageIndex(arguments)
      case "layout_char_to_page":
        result = try charToPage(arguments)
      case "save_read_page_changed":
        result = try saveRead(arguments)
      case "reset_progress":
        result = try reset(arguments)
      case "audio_save_read":
        result = try audioSave(arguments)
      default:
        throw ReaderProgressFixtureProjectionError.invalidFixture
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
    return ReaderProgressFixtureProjectionRun(
      artifact: .object([
        "schema_version": number(1),
        "fixture_id": .string(fixtureID),
        "engine": .object([
          "platform": .string("ios"),
          "revision": .string("reader-progress-runtime-v1"),
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

  private static func setPageIndex(
    _ arguments: [String: JSONValue]
  ) throws -> JSONValue {
    let pageIndex = try integer("page_index", in: arguments)
    let layout = try layout(arguments)
    let stored = snapshot(
      chapterIndex: 0,
      characterOffset: 0,
      chapterTitle: "既有标题"
    )
    guard
      let runtime = AndroidReaderProgressCompatibility.position(
        afterSelectingPage: pageIndex,
        current: stored.progress.position,
        layout: layout
      ),
      let runtimePage = layout.pageIndex(
        forCharacterOffset: runtime.characterOffset
      )
    else {
      throw ReaderProgressFixtureProjectionError.invalidFixture
    }
    let persisted = AndroidReaderProgressCompatibility.saving(
      stored: stored,
      runtimePosition: runtime,
      event: .pageChanged,
      nowMilliseconds: 2,
      resolvedChapterTitle: "第一章"
    )
    return .object([
      "requested_page_index": number(pageIndex),
      "runtime_char_position": number(runtime.characterOffset),
      "runtime_page_index": number(runtimePage),
      "persisted_chapter_index": number(
        persisted.progress.position.chapterIndex
      ),
      "persisted_char_position": number(
        persisted.progress.position.characterOffset
      ),
      "persisted_chapter_title": nullable(
        persisted.progress.chapterTitle
      ),
    ])
  }

  private static func charToPage(
    _ arguments: [String: JSONValue]
  ) throws -> JSONValue {
    let layout = try layout(arguments)
    guard case .array(let values)? = arguments["char_indices"] else {
      throw ReaderProgressFixtureProjectionError.invalidFixture
    }
    let mappings = try values.map { value -> JSONValue in
      let characterOffset = try integer(value)
      return .object([
        "char_index": number(characterOffset),
        "page_index": number(
          layout.pageIndex(
            forCharacterOffset: characterOffset
          ) ?? -1
        ),
      ])
    }
    return .object([
      "layout_completed": .bool(layout.isComplete),
      "mappings": .array(mappings),
    ])
  }

  private static func saveRead(
    _ arguments: [String: JSONValue]
  ) throws -> JSONValue {
    let storedIndex = try integer(
      "stored_chapter_index",
      in: arguments
    )
    let runtime = ReadingPosition(
      chapterIndex: try integer(
        "runtime_chapter_index",
        in: arguments
      ),
      characterOffset: try integer(
        "runtime_chapter_pos",
        in: arguments
      )
    )
    guard case .bool(let pageChanged)? = arguments["page_changed"] else {
      throw ReaderProgressFixtureProjectionError.invalidFixture
    }
    let persisted = AndroidReaderProgressCompatibility.saving(
      stored: snapshot(
        chapterIndex: storedIndex,
        characterOffset: 5,
        chapterTitle: "既有标题"
      ),
      runtimePosition: runtime,
      event: pageChanged ? .pageChanged : .lifecycle,
      nowMilliseconds: 2,
      resolvedChapterTitle: title(runtime.chapterIndex)
    )
    return saveProjection(
      persisted,
      pageChanged: .bool(pageChanged)
    )
  }

  private static func reset(
    _ arguments: [String: JSONValue]
  ) throws -> JSONValue {
    let stored = ReadingPosition(
      chapterIndex: try integer(
        "stored_chapter_index",
        in: arguments
      ),
      characterOffset: try integer(
        "stored_chapter_pos",
        in: arguments
      )
    )
    let runtime = AndroidReaderProgressCompatibility.resetPosition(
      stored: stored,
      chapterCount: 3
    )
    return .object([
      "chapter_size": number(3),
      "runtime_chapter_index": number(runtime.chapterIndex),
      "runtime_char_position": number(runtime.characterOffset),
      "persisted_chapter_index": number(stored.chapterIndex),
      "persisted_char_position": number(stored.characterOffset),
    ])
  }

  private static func audioSave(
    _ arguments: [String: JSONValue]
  ) throws -> JSONValue {
    let stored = snapshot(
      chapterIndex: try integer(
        "stored_chapter_index",
        in: arguments
      ),
      characterOffset: try integer(
        "stored_chapter_pos",
        in: arguments
      ),
      chapterTitle: "既有标题"
    )
    let persisted = AndroidReaderProgressCompatibility.saving(
      stored: stored,
      runtimePosition: stored.progress.position,
      event: .audio,
      nowMilliseconds: 2,
      resolvedChapterTitle: title(
        stored.progress.position.chapterIndex
      )
    )
    return saveProjection(persisted)
  }

  private static func saveProjection(
    _ snapshot: ReaderProgressSnapshot,
    pageChanged: JSONValue? = nil
  ) -> JSONValue {
    var value: [String: JSONValue] = [
      "persisted_chapter_index": number(
        snapshot.progress.position.chapterIndex
      ),
      "persisted_char_position": number(
        snapshot.progress.position.characterOffset
      ),
      "persisted_chapter_title": nullable(
        snapshot.progress.chapterTitle
      ),
      "last_check_count": number(snapshot.contentCheckCount),
      "timestamp_was_refreshed": .bool(
        snapshot.progress.updatedAtMilliseconds > 1
      ),
    ]
    value["page_changed"] = pageChanged
    return .object(value)
  }

  private static func layout(
    _ arguments: [String: JSONValue]
  ) throws -> ReaderLayoutMap {
    guard
      case .array(let starts)? = arguments["page_starts"],
      case .array(let texts)? = arguments["page_texts"],
      starts.count == texts.count,
      !starts.isEmpty,
      case .bool(let completed)? = arguments["layout_completed"]
    else {
      throw ReaderProgressFixtureProjectionError.invalidFixture
    }
    let pages = try zip(starts, texts).map {
      value,
      text -> ReaderLayoutPage in
      guard case .string(let rawText) = text else {
        throw ReaderProgressFixtureProjectionError.invalidFixture
      }
      return ReaderLayoutPage(
        startCharacterOffset: try integer(value),
        characterCount: rawText.utf16.count
      )
    }
    do {
      return try ReaderLayoutMap(
        pages: pages,
        isComplete: completed
      )
    } catch {
      throw ReaderProgressFixtureProjectionError.invalidFixture
    }
  }

  private static func snapshot(
    chapterIndex: Int,
    characterOffset: Int,
    chapterTitle: String?
  ) -> ReaderProgressSnapshot {
    ReaderProgressSnapshot(
      progress: ReadingProgress(
        position: ReadingPosition(
          chapterIndex: chapterIndex,
          characterOffset: characterOffset
        ),
        chapterTitle: chapterTitle,
        updatedAtMilliseconds: 1
      ),
      contentCheckCount: 7
    )
  }

  private static func title(_ chapterIndex: Int) -> String? {
    ["第一章", "第二章", "第三章"].indices.contains(chapterIndex)
      ? ["第一章", "第二章", "第三章"][chapterIndex]
      : nil
  }

  private static func integer(
    _ key: String,
    in arguments: [String: JSONValue]
  ) throws -> Int {
    guard let value = arguments[key] else {
      throw ReaderProgressFixtureProjectionError.invalidFixture
    }
    return try integer(value)
  }

  private static func integer(_ value: JSONValue) throws -> Int {
    guard
      case .number(let number) = value,
      let integer = Int(number.rawToken)
    else {
      throw ReaderProgressFixtureProjectionError.invalidFixture
    }
    return integer
  }

  private static func nullable(_ value: String?) -> JSONValue {
    value.map(JSONValue.string) ?? .null
  }

  private static func number(_ value: Int) -> JSONValue {
    .number(JSONNumber(Int64(value)))
  }
}

public enum ReaderPrefetchFixtureProjectionError: Error, Sendable {
  case invalidFixture
}

public struct ReaderPrefetchFixtureProjectionRun: Sendable {
  public let artifact: JSONValue
  public let requestPlan: JSONValue

  public init(artifact: JSONValue, requestPlan: JSONValue) {
    self.artifact = artifact
    self.requestPlan = requestPlan
  }
}

public enum ReaderPrefetchFixtureProjection {
  public static let fixtureID =
    "rl-reader-cache-prefetch-policy-001"

  private struct ParsedInput {
    let policy: ReaderPrefetchPolicyInput
    let cachedIndices: Set<Int>
    let failures: [ReaderPrefetchFailure]
  }

  public static func run(
    caseData: Data,
    inputData: Data
  ) throws -> ReaderPrefetchFixtureProjectionRun {
    let caseDocument: JSONValue
    let inputDocument: JSONValue
    do {
      caseDocument = try JSONValueCodec.decode(caseData)
      inputDocument = try JSONValueCodec.decode(inputData)
    } catch {
      throw ReaderPrefetchFixtureProjectionError.invalidFixture
    }
    guard
      case .object(let caseRoot) = caseDocument,
      caseRoot["id"] == .string(fixtureID),
      caseRoot["kind"] == .string("android_runtime_scenario"),
      caseRoot["operation"] == .string("android_runtime"),
      case .object(let inputRoot) = inputDocument,
      case .array(let inputCases)? = inputRoot["cases"]
    else {
      throw ReaderPrefetchFixtureProjectionError.invalidFixture
    }

    var identifiers: Set<String> = []
    var plans: [JSONValue] = []
    var cases: [JSONValue] = []
    for value in inputCases {
      guard
        case .object(let inputCase) = value,
        case .string(let id)? = inputCase["id"],
        identifiers.insert(id).inserted,
        case .string(let operation)? = inputCase["operation"],
        operation == "reader_prefetch_policy",
        case .object(let arguments)? = inputCase["arguments"]
      else {
        throw ReaderPrefetchFixtureProjectionError.invalidFixture
      }
      plans.append(
        .object([
          "operation": .string(operation),
          "arguments": .object(arguments),
        ])
      )
      cases.append(
        .object([
          "id": .string(id),
          "operation": .string(operation),
          "result": try result(arguments),
          "issue": .null,
        ])
      )
    }

    let requestPlan = JSONValue.array(plans)
    return ReaderPrefetchFixtureProjectionRun(
      artifact: .object([
        "schema_version": number(1),
        "fixture_id": .string(fixtureID),
        "engine": .object([
          "platform": .string("ios"),
          "revision": .string("reader-prefetch-policy-v1"),
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

  private static func result(
    _ arguments: [String: JSONValue]
  ) throws -> JSONValue {
    guard case .string(let mode)? = arguments["mode"] else {
      throw ReaderPrefetchFixtureProjectionError.invalidFixture
    }
    let parsed = try parse(arguments)
    switch mode {
    case "settled":
      return try settled(parsed)
    case "observe_workers":
      return observeWorkers(parsed)
    case "replace_job":
      return try replaceJob(arguments, parsed: parsed)
    default:
      throw ReaderPrefetchFixtureProjectionError.invalidFixture
    }
  }

  private static func settled(
    _ parsed: ParsedInput
  ) throws -> JSONValue {
    let plan = AndroidReaderPrefetchPolicy.plan(for: parsed.policy)
    let commandIndices = Set(
      plan.commands.map(\.chapterIndex)
    )
    guard commandIndices.isSubset(of: parsed.cachedIndices) else {
      throw ReaderPrefetchFixtureProjectionError.invalidFixture
    }
    let downloaded = parsed.policy.completedChapterIndices
      .union(commandIndices)
      .sorted()
    return .object([
      "downloaded_indices": numbers(downloaded),
      "failure_counts": failureValues(parsed.failures),
      "loading_indices": .array([]),
      "task_completed": .bool(plan.taskCreated),
      "task_created": .bool(plan.taskCreated),
    ])
  }

  private static func observeWorkers(
    _ parsed: ParsedInput
  ) -> JSONValue {
    let plan = AndroidReaderPrefetchPolicy.plan(for: parsed.policy)
    return .object([
      "child_job_count": number(plan.workerCount),
      "directions_started": .bool(plan.workerCount == 2),
      "initial_loading_indices": numbers(
        plan.initialChapterIndices
      ),
      "task_created": .bool(plan.taskCreated),
    ])
  }

  private static func replaceJob(
    _ arguments: [String: JSONValue],
    parsed: ParsedInput
  ) throws -> JSONValue {
    let replacementChapter = try integer(
      "replacement_current_chapter",
      in: arguments
    )
    var state = ReaderPrefetchGenerationState()
    let first = state.replace(using: parsed.policy)
    let replacementInput = ReaderPrefetchPolicyInput(
      isLocalBook: parsed.policy.isLocalBook,
      chapterCount: parsed.policy.chapterCount,
      currentChapterIndex: replacementChapter,
      configuredCount: parsed.policy.configuredCount,
      completedChapterIndices:
        parsed.policy.completedChapterIndices,
      failures: parsed.policy.failures
    )
    let second = state.replace(using: replacementInput)
    let firstGeneration = first.replacement
    let replacement = second.replacement
    return .object([
      "first_task_cancelled": .bool(
        second.cancelled?.id == firstGeneration?.id
      ),
      "replacement_current_chapter": number(
        replacement?.currentChapterIndex ?? -1
      ),
      "replacement_task_created": .bool(replacement != nil),
      "task_identity_changed": .bool(
        firstGeneration?.id != replacement?.id
      ),
    ])
  }

  private static func parse(
    _ arguments: [String: JSONValue]
  ) throws -> ParsedInput {
    guard
      case .bool(let localBook)? = arguments["local_book"]
    else {
      throw ReaderPrefetchFixtureProjectionError.invalidFixture
    }
    let cached = Set(
      try integerArray("cached_indices", in: arguments)
    )
    let completed = Set(
      try integerArray(
        "pre_downloaded_indices",
        in: arguments
      )
    )
    let failures = try failureCounts(arguments)
    return ParsedInput(
      policy: ReaderPrefetchPolicyInput(
        isLocalBook: localBook,
        chapterCount: try integer(
          "chapter_size",
          in: arguments
        ),
        currentChapterIndex: try integer(
          "current_chapter",
          in: arguments
        ),
        configuredCount: try integer(
          "pre_download_num",
          in: arguments
        ),
        completedChapterIndices: completed,
        failures: failures
      ),
      cachedIndices: cached,
      failures: failures
    )
  }

  private static func failureCounts(
    _ arguments: [String: JSONValue]
  ) throws -> [ReaderPrefetchFailure] {
    guard case .array(let values)? = arguments["failure_counts"] else {
      throw ReaderPrefetchFixtureProjectionError.invalidFixture
    }
    return try values.map { value in
      guard case .object(let failure) = value else {
        throw ReaderPrefetchFixtureProjectionError.invalidFixture
      }
      return ReaderPrefetchFailure(
        chapterIndex: try integer("index", in: failure),
        count: try integer("count", in: failure)
      )
    }
  }

  private static func failureValues(
    _ failures: [ReaderPrefetchFailure]
  ) -> JSONValue {
    .array(
      failures.sorted {
        $0.chapterIndex < $1.chapterIndex
      }.map { failure in
        .object([
          "count": number(failure.count),
          "index": number(failure.chapterIndex),
        ])
      }
    )
  }

  private static func integerArray(
    _ key: String,
    in arguments: [String: JSONValue]
  ) throws -> [Int] {
    guard case .array(let values)? = arguments[key] else {
      throw ReaderPrefetchFixtureProjectionError.invalidFixture
    }
    return try values.map(integer)
  }

  private static func integer(
    _ key: String,
    in arguments: [String: JSONValue]
  ) throws -> Int {
    guard let value = arguments[key] else {
      throw ReaderPrefetchFixtureProjectionError.invalidFixture
    }
    return try integer(value)
  }

  private static func integer(_ value: JSONValue) throws -> Int {
    guard
      case .number(let number) = value,
      let integer = Int(number.rawToken)
    else {
      throw ReaderPrefetchFixtureProjectionError.invalidFixture
    }
    return integer
  }

  private static func numbers(_ values: [Int]) -> JSONValue {
    .array(values.map(number))
  }

  private static func number(_ value: Int) -> JSONValue {
    .number(JSONNumber(Int64(value)))
  }
}

public enum ReaderTOCRemapFixtureProjectionError:
  Error, Sendable
{
  case invalidFixture
}

public struct ReaderTOCRemapFixtureProjectionRun: Sendable {
  public let artifact: JSONValue
  public let requestPlan: JSONValue

  public init(artifact: JSONValue, requestPlan: JSONValue) {
    self.artifact = artifact
    self.requestPlan = requestPlan
  }
}

public enum ReaderTOCRemapFixtureProjection {
  public static let fixtureID =
    "rl-reader-progress-toc-remap-001"

  public static func run(
    caseData: Data,
    inputData: Data
  ) throws -> ReaderTOCRemapFixtureProjectionRun {
    let caseDocument: JSONValue
    let inputDocument: JSONValue
    do {
      caseDocument = try JSONValueCodec.decode(caseData)
      inputDocument = try JSONValueCodec.decode(inputData)
    } catch {
      throw ReaderTOCRemapFixtureProjectionError.invalidFixture
    }
    guard
      case .object(let caseRoot) = caseDocument,
      caseRoot["id"] == .string(fixtureID),
      caseRoot["kind"] == .string("android_runtime_scenario"),
      caseRoot["operation"] == .string("android_runtime"),
      case .object(let inputRoot) = inputDocument,
      case .array(let inputCases)? = inputRoot["cases"]
    else {
      throw ReaderTOCRemapFixtureProjectionError.invalidFixture
    }

    var identifiers: Set<String> = []
    var plans: [JSONValue] = []
    var cases: [JSONValue] = []
    for value in inputCases {
      guard
        case .object(let inputCase) = value,
        case .string(let id)? = inputCase["id"],
        identifiers.insert(id).inserted,
        case .string(let operation)? = inputCase["operation"],
        operation == "reader_progress_toc_remap",
        case .object(let arguments)? = inputCase["arguments"]
      else {
        throw ReaderTOCRemapFixtureProjectionError.invalidFixture
      }
      plans.append(
        .object([
          "operation": .string(operation),
          "arguments": .object(arguments),
        ])
      )
      cases.append(
        .object([
          "id": .string(id),
          "operation": .string(operation),
          "result": try result(arguments),
          "issue": .null,
        ])
      )
    }

    let requestPlan = JSONValue.array(plans)
    return ReaderTOCRemapFixtureProjectionRun(
      artifact: .object([
        "schema_version": number(1),
        "fixture_id": .string(fixtureID),
        "engine": .object([
          "platform": .string("ios"),
          "revision": .string("reader-toc-remap-policy-v1"),
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

  private static func result(
    _ arguments: [String: JSONValue]
  ) throws -> JSONValue {
    let oldTitle: String?
    switch arguments["old_title"] {
    case .string(let value):
      oldTitle = value
    case .null:
      oldTitle = nil
    default:
      throw ReaderTOCRemapFixtureProjectionError.invalidFixture
    }
    guard case .array(let titleValues)? = arguments["new_titles"] else {
      throw ReaderTOCRemapFixtureProjectionError.invalidFixture
    }
    let titles = try titleValues.map { value in
      guard case .string(let title) = value else {
        throw ReaderTOCRemapFixtureProjectionError.invalidFixture
      }
      return title
    }
    let remap: ReaderTOCRemapResult
    do {
      remap = try AndroidReaderTOCRemapPolicy.remap(
        ReaderTOCRemapInput(
          oldChapterIndex: try integer(
            "old_index",
            in: arguments
          ),
          oldChapterTitle: oldTitle,
          oldChapterListSize: try integer(
            "old_list_size",
            in: arguments
          ),
          newChapterTitles: titles
        )
      )
    } catch {
      throw ReaderTOCRemapFixtureProjectionError.invalidFixture
    }
    return .object([
      "new_chapter_count": number(remap.newChapterCount),
      "selected_index": number(remap.selectedIndex),
      "selected_index_in_bounds": .bool(
        remap.selectedIndexInBounds
      ),
      "selected_title": nullable(remap.selectedTitle),
    ])
  }

  private static func integer(
    _ key: String,
    in arguments: [String: JSONValue]
  ) throws -> Int {
    guard
      case .number(let number)? = arguments[key],
      let integer = Int(number.rawToken)
    else {
      throw ReaderTOCRemapFixtureProjectionError.invalidFixture
    }
    return integer
  }

  private static func nullable(_ value: String?) -> JSONValue {
    value.map(JSONValue.string) ?? .null
  }

  private static func number(_ value: Int) -> JSONValue {
    .number(JSONNumber(Int64(value)))
  }
}
