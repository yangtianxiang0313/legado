import Foundation
import LegadoCore
import SourceRuntime

struct SourceSearchPipelineConformanceRun: Sendable {
  let artifact: JSONValue
  let requestPlan: JSONValue
}

enum SourceSearchPipelineConformanceRunner {
  static let fixtureID = "sl-source-pipeline-search-runtime-001"

  static func run(
    fixtureDirectory: URL
  ) async throws -> SourceSearchPipelineConformanceRun {
    let caseDocument = try json(
      at: fixtureDirectory.appendingPathComponent("case.json")
    )
    let inputDocument = try json(
      at: fixtureDirectory.appendingPathComponent("input.json")
    )
    guard
      case .object(let caseRoot) = caseDocument,
      caseRoot["id"] == .string(fixtureID),
      case .object(let determinism)? = caseRoot["determinism"],
      case .string(let origin)? = determinism["logical_origin"],
      case .string(let sourcePath)? = caseRoot["source"],
      case .object(let inputRoot) = inputDocument,
      case .array(let inputCases)? = inputRoot["cases"]
    else {
      throw SourcePipelineConformanceError.invalidSourceDefinition
    }

    let sourceURL = fixtureDirectory.appendingPathComponent(sourcePath)
    let sourceTemplate = try Data(contentsOf: sourceURL)
    let sourceData = Data(
      String(decoding: sourceTemplate, as: UTF8.self)
        .replacingOccurrences(
          of: "${SOURCE_LAB_ORIGIN}",
          with: origin
        ).utf8
    )
    let baseRuntime = try SourcePipelineConformanceRunner.definition(
      from: sourceData
    )
    let metadata = try sourceMetadata(from: sourceData)
    var plans: [JSONValue] = []
    var projectedCases: [JSONValue] = []

    for value in inputCases {
      guard
        case .object(let inputCase) = value,
        case .string(let id)? = inputCase["id"],
        inputCase["operation"] == .string("search_pipeline"),
        case .object(let arguments)? = inputCase["arguments"],
        case .string(let keyword)? = arguments["keyword"],
        case .number(let pageNumber)? = arguments["page"],
        let page = Int(pageNumber.rawToken),
        case .string(let mode)? = arguments["mode"]
      else {
        throw SourcePipelineConformanceError.invalidSourceDefinition
      }

      let requestPlan: JSONValue
      let result: JSONValue
      let issue: JSONValue
      do {
        let runtime =
          mode == "blank_url"
          ? replacingSearchURL("", in: baseRuntime)
          : baseRuntime
        let body = try responseBody(
          for: id,
          fixtureDirectory: fixtureDirectory
        )
        let transport = SearchConformanceTransport(body: body)
        let checker: any SourceSearchResponseChecking =
          mode == "login_check_transform"
          ? SearchConformanceUnlockingChecker()
          : IdentitySourceSearchResponseChecker()
        let definition = SourceSearchDefinition(
          sourceURL: metadata.sourceURL,
          sourceName: metadata.sourceName,
          originOrder: metadata.originOrder,
          bookURLPattern:
            mode == "detail_pattern"
            ? #".*/pipeline/search/4.*"#
            : nil,
          runtime: runtime
        )
        let execution = try await SourceSearchPipeline(
          definition: definition,
          transport: transport,
          responseChecker: checker
        ).search(SourceSearchInput(keyword: keyword, page: page))
        requestPlan = plan(execution.requestPlan.request)
        result = projection(execution.books)
        issue = .null
      } catch let runtimeIssue as SourceRuntimeIssue {
        guard mode == "blank_url" else { throw runtimeIssue }
        requestPlan = plan(
          method: "GET",
          url: origin + "/pipeline/no-request"
        )
        result = .null
        issue = .object([
          "stage": .string(runtimeIssue.stage.rawValue),
          "code": .string(runtimeIssue.code.rawValue),
        ])
      }
      plans.append(requestPlan)
      projectedCases.append(
        .object([
          "id": .string(id),
          "operation": .string("search_pipeline"),
          "result": result,
          "issue": issue,
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
            "cases": .array(projectedCases)
          ])
        ]),
      ]),
      "issues": .array([]),
    ])
    return SourceSearchPipelineConformanceRun(
      artifact: artifact,
      requestPlan: canonicalPlans
    )
  }

  private struct Metadata {
    let sourceURL: String
    let sourceName: String
    let originOrder: Int
  }

  private static func sourceMetadata(from data: Data) throws -> Metadata {
    guard
      case .object(let source) = try JSONValueCodec.decode(data),
      case .string(let sourceURL)? = source["bookSourceUrl"],
      case .string(let sourceName)? = source["bookSourceName"],
      case .number(let order)? = source["customOrder"],
      let originOrder = Int(order.rawToken)
    else {
      throw SourcePipelineConformanceError.invalidSourceDefinition
    }
    return Metadata(
      sourceURL: sourceURL,
      sourceName: sourceName,
      originOrder: originOrder
    )
  }

  private static func replacingSearchURL(
    _ searchURL: String,
    in definition: HTMLCSSSourceDefinition
  ) -> HTMLCSSSourceDefinition {
    HTMLCSSSourceDefinition(
      searchURLTemplate: searchURL,
      search: definition.search,
      bookInfo: definition.bookInfo,
      toc: definition.toc,
      content: definition.content
    )
  }

  private static func responseBody(
    for caseID: String,
    fixtureDirectory: URL
  ) throws -> String {
    let filename: String
    switch caseID {
    case "page-one-deduplicate":
      filename = "page-one.html"
    case "page-two-partial-fields":
      filename = "page-two.html"
    case "login-check-body-transform":
      filename = "login-transform.html"
    case "detail-pattern-shortcut":
      filename = "direct-detail.html"
    case "blank-search-url":
      return ""
    default:
      throw SourcePipelineConformanceError.invalidSourceDefinition
    }
    return try String(
      contentsOf:
        fixtureDirectory
        .appendingPathComponent("responses")
        .appendingPathComponent(filename),
      encoding: .utf8
    )
  }

  private static func projection(
    _ books: [SourceSearchBook]
  ) -> JSONValue {
    .object([
      "book_count": .number(JSONNumber(Int64(books.count))),
      "books": .array(
        books.map { book in
          .object([
            "name": .string(book.name),
            "author": .string(book.author),
            "kind": .string(book.kind),
            "word_count": .string(book.wordCount),
            "intro": .string(book.intro),
            "last_chapter": .string(book.lastChapter),
            "book_url": .string(book.bookURL),
            "cover_url": book.coverURL.map(JSONValue.string) ?? .null,
            "origin": .string(book.origin),
            "origin_name": .string(book.originName),
            "origin_order": .number(
              JSONNumber(Int64(book.originOrder))
            ),
            "info_html_present": .bool(book.infoHTML != nil),
          ])
        }
      ),
    ])
  }

  private static func plan(_ request: HTTPRequest) -> JSONValue {
    plan(
      method: request.method.rawValue,
      url:
        request.url.absoluteString.removingPercentEncoding
        ?? request.url.absoluteString
    )
  }

  private static func plan(method: String, url: String) -> JSONValue {
    .object([
      "method": .string(method),
      "url": .string(url),
      "headers": .array([]),
      "body": .null,
      "timeout_ms": .null,
    ])
  }

  private static func json(at url: URL) throws -> JSONValue {
    do {
      return try JSONValueCodec.decode(Data(contentsOf: url))
    } catch {
      throw SourcePipelineConformanceError.invalidSourceDefinition
    }
  }
}

private actor SearchConformanceTransport: HTTPTransport {
  private let body: String

  init(body: String) {
    self.body = body
  }

  func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
    try HTTPResponse(
      statusCode: 200,
      effectiveURL: request.url,
      body: HTTPBody(Data(body.utf8))
    )
  }
}

private struct SearchConformanceUnlockingChecker:
  SourceSearchResponseChecking
{
  func check(
    _ response: SourceSearchResponse,
    source: SourceSearchDefinition,
    input: SourceSearchInput
  ) async throws -> SourceSearchResponse {
    SourceSearchResponse(
      url: response.url,
      body: response.body.replacingOccurrences(
        of: "locked-item",
        with: "book-item"
      )
    )
  }
}
