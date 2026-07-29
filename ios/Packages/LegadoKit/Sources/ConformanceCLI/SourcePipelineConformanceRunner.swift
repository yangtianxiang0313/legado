import Foundation
import LegadoCore
import SourceRuntime
import TestSupport

public enum SourcePipelineConformanceError: String, Error, Equatable, Sendable {
  case invalidSourceDefinition = "invalid_source_definition"
  case inputRouteMismatch = "input_route_mismatch"
  case invalidResponseEncoding = "invalid_response_encoding"
  case unsupportedOperation = "unsupported_operation"
}

struct SourceRequestOptionInput: Equatable, Sendable {
  let persistentCookie: String
  let optionHeaders: [SourceHeaderField]
  let retry: Int
}

struct SourcePipelineInput: Equatable, Sendable {
  var searchKeywords: [String: String] = [:]
  var requestOptions: [String: SourceRequestOptionInput] = [:]
}

public enum SourcePipelineConformanceRunner {
  public static func run(
    _ fixture: LoadedFixture,
    searchKeywords: [String: String] = [:]
  ) async throws -> Data {
    try await run(
      fixture,
      input: SourcePipelineInput(searchKeywords: searchKeywords)
    )
  }

  static func run(
    _ fixture: LoadedFixture,
    input: SourcePipelineInput
  ) async throws -> Data {
    guard
      fixture.definition.operation == .sourceLabSite,
      fixture.definition.transport.mode == .fixtureAndLoopback
    else {
      throw SourcePipelineConformanceError.invalidSourceDefinition
    }

    let runtime = HTMLCSSSourceRuntime(definition: try definition(from: fixture.sourceData))
    let transport = FixtureTransport(fixture: fixture)
    var requestPlan: [HTTPRequestEnvelope] = []
    var cases: [JSONValue] = []
    var routeRequestCounts: [JSONValue] = []
    let plans = try compiledPlans(
      fixture,
      input: input
    )

    for requestCase in fixture.requestCases {
      guard let plan = plans[requestCase.id] else {
        throw SourcePipelineConformanceError.inputRouteMismatch
      }
      let request = plan.request
      guard
        request.method == requestCase.request.method,
        request.url == requestCase.request.url
      else {
        throw SourcePipelineConformanceError.inputRouteMismatch
      }

      if requestCase.operation == .requestOptions {
        guard let stimulus = input.requestOptions[requestCase.id] else {
          throw SourcePipelineConformanceError.inputRouteMismatch
        }
        let preparation = try requestPreparation(
          fixture: fixture,
          requestCase: requestCase,
          input: stimulus
        )
        let execution = try await SourceRequestExecutor(transport: transport).execute(
          preparation.networkRequest,
          retry: preparation.retry
        )
        requestPlan.append(HTTPRequestEnvelope(request: preparation.constructedRequest))
        cases.append(
          try requestOptionsCase(
            requestCase,
            preparation: preparation,
            response: execution.response
          )
        )
        routeRequestCounts.append(
          .object([
            "request_count": .number(JSONNumber(Int64(execution.attemptCount))),
            "route_id": .string(requestCase.id),
          ])
        )
        continue
      }

      let response = try await transport.execute(request)
      guard response.statusCode < 400 else {
        // Android's protected portable projection contains only cases for which
        // the characterization runner reached source parsing. HTTP failures stay
        // covered by the generic transport transcript and are not fabricated here.
        continue
      }
      requestPlan.append(HTTPRequestEnvelope(request: request))
      if requestCase.operation == .rawResponse {
        let normalized = try SourceStringResponseNormalizer.normalize(response)
        cases.append(rawResponseCase(requestCase, response: normalized))
        continue
      }
      guard let html = String(data: response.body.bytes, encoding: .utf8) else {
        throw SourcePipelineConformanceError.invalidResponseEncoding
      }
      cases.append(
        try pipelineCase(
          requestCase,
          html: html,
          response: response,
          runtime: runtime
        )
      )
    }

    var resultValue: [String: JSONValue] = [
      "portable_known_projection": .object([
        "cases": .array(cases)
      ])
    ]
    if !routeRequestCounts.isEmpty {
      resultValue["source_lab_observation"] = .object([
        "route_request_counts": .array(routeRequestCounts)
      ])
    }

    let envelope = ExecutionEnvelope(
      fixtureID: fixture.definition.id,
      engine: ExecutionEngine(
        platform: .ios,
        revision: "conformance-source-runtime-v2",
        compatibilityProfile: fixture.definition.compatibilityProfile
      ),
      requestPlan: requestPlan,
      decode: nil,
      stages: [],
      result: ExecutionResult(
        type: "source_pipeline",
        value: .object(resultValue)
      ),
      issues: []
    )
    return try ExecutionEnvelopeCodec.artifactData(envelope)
  }

  static func definition(from data: Data) throws -> HTMLCSSSourceDefinition {
    guard
      case .object(let source) = try? JSONValueCodec.decode(data),
      case .string(let searchURL)? = source["searchUrl"],
      case .object(let search)? = source["ruleSearch"],
      case .object(let bookInfo)? = source["ruleBookInfo"],
      case .object(let toc)? = source["ruleToc"],
      case .object(let content)? = source["ruleContent"]
    else {
      throw SourcePipelineConformanceError.invalidSourceDefinition
    }

    return try HTMLCSSSourceDefinition(
      searchURLTemplate: searchURL,
      search: SearchRules(
        list: selector(search, "bookList"),
        name: rule(search, "name"),
        author: optionalRule(search, "author"),
        intro: optionalRule(search, "intro"),
        kind: optionalRule(search, "kind"),
        lastChapter: optionalRule(search, "lastChapter"),
        bookURL: rule(search, "bookUrl"),
        coverURL: optionalRule(search, "coverUrl")
      ),
      bookInfo: BookInfoRules(
        name: rule(bookInfo, "name"),
        author: optionalRule(bookInfo, "author"),
        intro: optionalRule(bookInfo, "intro"),
        kind: optionalRule(bookInfo, "kind"),
        lastChapter: optionalRule(bookInfo, "lastChapter"),
        coverURL: optionalRule(bookInfo, "coverUrl"),
        tocURL: rule(bookInfo, "tocUrl")
      ),
      toc: TOCRules(
        list: selector(toc, "chapterList"),
        name: rule(toc, "chapterName"),
        url: rule(toc, "chapterUrl")
      ),
      content: ContentRules(content: rule(content, "content"))
    )
  }

  private static func selector(
    _ object: [String: JSONValue],
    _ key: String
  ) throws -> String {
    guard
      case .string(let raw)? = object[key],
      raw.hasPrefix("@CSS:"),
      raw.count > 5
    else {
      throw SourcePipelineConformanceError.invalidSourceDefinition
    }
    return String(raw.dropFirst(5))
  }

  private static func rule(
    _ object: [String: JSONValue],
    _ key: String
  ) throws -> HTMLCSSRule {
    let raw = try selector(object, key)
    for value in [
      HTMLCSSRule.Value.text,
      .href,
      .src,
      .html,
    ] {
      let suffix = "@\(value.rawValue)"
      if raw.hasSuffix(suffix) {
        let selector = String(raw.dropLast(suffix.count))
        guard !selector.isEmpty else {
          throw SourcePipelineConformanceError.invalidSourceDefinition
        }
        return HTMLCSSRule(selector, value: value)
      }
    }
    guard !raw.isEmpty else {
      throw SourcePipelineConformanceError.invalidSourceDefinition
    }
    return HTMLCSSRule(raw)
  }

  private static func optionalRule(
    _ object: [String: JSONValue],
    _ key: String
  ) -> HTMLCSSRule {
    (try? rule(object, key)) ?? HTMLCSSRule("[data-legado-missing-field]")
  }

  static func compiledPlans(
    _ fixture: LoadedFixture,
    input: SourcePipelineInput
  ) throws -> [String: SourceRequestPlan] {
    let runtime = HTMLCSSSourceRuntime(
      definition: try definition(from: fixture.sourceData)
    )
    var plans: [String: SourceRequestPlan] = [:]
    for requestCase in fixture.requestCases {
      let plan: SourceRequestPlan
      switch requestCase.operation {
      case .search:
        let queryKeyword = URLComponents(
          string: requestCase.request.url.absoluteString
        )?.queryItems?.first(where: { $0.name == "q" })?.value
        guard let keyword = input.searchKeywords[requestCase.id] ?? queryKeyword else {
          throw SourcePipelineConformanceError.inputRouteMismatch
        }
        plan = try runtime.searchRequestPlan(keyword: keyword)
      case .bookInfo, .chapters, .content:
        guard let url = URL(string: requestCase.request.url.absoluteString) else {
          throw SourcePipelineConformanceError.inputRouteMismatch
        }
        plan = SourceRequestPlan(
          request: try runtime.request(for: url),
          body: nil,
          formFields: []
        )
      case .rawResponse:
        plan = SourceRequestPlan(
          request: HTTPRequest(
            method: requestCase.request.method,
            url: requestCase.request.url,
            headers: requestCase.request.headers
          ),
          body: nil,
          formFields: []
        )
      case .requestOptions:
        guard let stimulus = input.requestOptions[requestCase.id] else {
          throw SourcePipelineConformanceError.inputRouteMismatch
        }
        let preparation = try requestPreparation(
          fixture: fixture,
          requestCase: requestCase,
          input: stimulus
        )
        plan = SourceRequestPlan(
          request: preparation.constructedRequest,
          body: nil,
          formFields: [],
          retry: preparation.retry
        )
      default:
        throw SourcePipelineConformanceError.unsupportedOperation
      }
      plans[requestCase.id] = plan
    }
    return plans
  }

  private static func requestPreparation(
    fixture: LoadedFixture,
    requestCase: FixtureRequestCase,
    input: SourceRequestOptionInput
  ) throws -> SourceRequestPreparation {
    let configuration = try requestConfiguration(from: fixture.sourceData)
    return try SourceRequestPreparer.prepare(
      request: HTTPRequest(
        method: requestCase.request.method,
        url: requestCase.request.url
      ),
      inheritedHeaders: configuration.headers,
      optionHeaders: input.optionHeaders,
      persistentCookie: input.persistentCookie,
      enabledCookieJar: configuration.enabledCookieJar,
      retry: input.retry
    )
  }

  private static func requestConfiguration(
    from data: Data
  ) throws -> (headers: [SourceHeaderField], enabledCookieJar: Bool) {
    guard case .object(let source) = try? JSONValueCodec.decode(data) else {
      throw SourcePipelineConformanceError.invalidSourceDefinition
    }
    let enabledCookieJar: Bool
    if case .bool(let enabled)? = source["enabledCookieJar"] {
      enabledCookieJar = enabled
    } else {
      enabledCookieJar = false
    }
    guard case .string(let headerText)? = source["header"] else {
      return ([], enabledCookieJar)
    }
    guard
      case .object(let headerObject) = try? JSONValueCodec.decode(Data(headerText.utf8))
    else {
      throw SourcePipelineConformanceError.invalidSourceDefinition
    }
    let headers = try headerObject.map { name, value -> SourceHeaderField in
      guard case .string(let stringValue) = value else {
        throw SourcePipelineConformanceError.invalidSourceDefinition
      }
      return try SourceHeaderField(name: name, value: stringValue)
    }
    return (headers, enabledCookieJar)
  }

  private static func pipelineCase(
    _ requestCase: FixtureRequestCase,
    html: String,
    response: HTTPResponse,
    runtime: HTMLCSSSourceRuntime
  ) throws -> JSONValue {
    guard let responseURL = URL(string: response.effectiveURL.absoluteString) else {
      throw SourcePipelineConformanceError.inputRouteMismatch
    }
    let result: JSONValue
    let issue: JSONValue

    do {
      switch requestCase.operation {
      case .search:
        let books = try runtime.search(html: html, responseURL: responseURL)
        result = .object([
          "books": .array(books.map(searchBookValue))
        ])
      case .bookInfo:
        result = bookInfoValue(
          try runtime.bookInfo(html: html, bookURL: responseURL)
        )
      case .chapters:
        let chapters = try runtime.chapters(html: html, tocURL: responseURL)
        result = .object([
          "chapters": .array(chapters.map(chapterValue))
        ])
      case .content:
        result = contentValue(
          try runtime.content(html: html, chapterURL: responseURL)
        )
      default:
        throw SourcePipelineConformanceError.unsupportedOperation
      }
      issue = .null
    } catch let runtimeIssue as SourceRuntimeIssue {
      result = .null
      issue = .object([
        "stage": .string(runtimeIssue.stage.rawValue),
        "code": .string(runtimeIssue.code.rawValue),
      ])
    }

    return .object([
      "id": .string(requestCase.id),
      "operation": .string(requestCase.operation.rawValue),
      "result": result,
      "issue": issue,
    ])
  }

  private static func rawResponseCase(
    _ requestCase: FixtureRequestCase,
    response: SourceStringResponse
  ) -> JSONValue {
    .object([
      "id": .string(requestCase.id),
      "operation": .string(requestCase.operation.rawValue),
      "result": .object([
        "body": .string(response.body),
        "final_url": .string(response.finalURL.absoluteString),
      ]),
      "issue": .null,
    ])
  }

  private static func requestOptionsCase(
    _ requestCase: FixtureRequestCase,
    preparation: SourceRequestPreparation,
    response: HTTPResponse
  ) throws -> JSONValue {
    guard let body = String(data: response.body.bytes, encoding: .utf8) else {
      throw SourcePipelineConformanceError.invalidResponseEncoding
    }
    return .object([
      "id": .string(requestCase.id),
      "operation": .string(requestCase.operation.rawValue),
      "result": .object([
        "body": .string(body),
        "constructed_headers": headerValue(preparation.constructedHeaders),
        "final_url": .string(response.effectiveURL.absoluteString),
        "inherited_headers": headerValue(preparation.inheritedHeaders),
        "network_headers": headerValue(preparation.networkHeaders),
        "resolved_headers": headerValue(preparation.resolvedHeaders),
        "retry": .number(JSONNumber(Int64(preparation.retry))),
        "status_code": .number(JSONNumber(Int64(response.statusCode))),
      ]),
      "issue": .null,
    ])
  }

  private static func headerValue(_ fields: [SourceHeaderField]) -> JSONValue {
    .array(
      fields.map { field in
        .object([
          "name": .string(field.name),
          "value": .string(field.value),
        ])
      }
    )
  }

  private static func searchBookValue(_ book: SourceBook) -> JSONValue {
    .object([
      "name": .string(book.name),
      "author": optional(book.author),
      "intro": .string(book.intro ?? ""),
      "kind": optional(book.kind),
      "last_chapter": .string(book.lastChapter ?? ""),
      "book_url": .string(book.bookURL.absoluteString),
      "cover_url": optional(book.coverURL?.absoluteString),
    ])
  }

  private static func bookInfoValue(_ book: SourceBook) -> JSONValue {
    .object([
      "name": .string(book.name),
      "author": optional(book.author),
      "intro": optional(book.intro),
      "kind": optional(book.kind),
      "last_chapter": optional(book.lastChapter),
      "book_url": .string(book.bookURL.absoluteString),
      "cover_url": optional(book.coverURL?.absoluteString),
      "toc_url": optional(book.tocURL?.absoluteString),
    ])
  }

  private static func chapterValue(_ chapter: SourceChapter) -> JSONValue {
    .object([
      "index": .number(JSONNumber(Int64(chapter.index))),
      "title": .string(chapter.title),
      "url": .string(chapter.url.absoluteString),
      "is_pay": .bool(chapter.isPay),
      "is_vip": .bool(chapter.isVIP),
      "is_volume": .bool(chapter.isVolume),
    ])
  }

  private static func contentValue(_ content: SourceContent) -> JSONValue {
    .object([
      "chapter_url": .string(content.chapterURL.absoluteString),
      "content": .string(content.content),
    ])
  }

  private static func optional(_ value: String?) -> JSONValue {
    value.map(JSONValue.string) ?? .null
  }
}
