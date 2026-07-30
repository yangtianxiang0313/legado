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

struct SourceFieldEncodingInput: Equatable, Sendable {
  let method: HTTPMethod
  let fields: String
  let charset: String?
}

struct SourceURLTemplateInput: Equatable, Sendable {
  let template: String
  let key: String?
  let page: Int?
  let basePath: String?
}

struct SourceRateLimitInput: Equatable, Sendable {
  let mode: String
  let concurrentRate: String
}

struct SourcePipelineInput: Equatable, Sendable {
  var searchKeywords: [String: String] = [:]
  var requestOptions: [String: SourceRequestOptionInput] = [:]
  var fieldEncodings: [String: SourceFieldEncodingInput] = [:]
  var urlTemplates: [String: SourceURLTemplateInput] = [:]
  var rateLimits: [String: SourceRateLimitInput] = [:]
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
    let rateLimiter = SourceRateLimiter(
      clock: SourceConformanceFixedClock(milliseconds: 1_000_000)
    )
    let plans = try compiledPlans(
      fixture,
      input: input
    )

    for requestCase in fixture.requestCases {
      guard let plan = plans[requestCase.id] else {
        throw SourcePipelineConformanceError.inputRouteMismatch
      }
      let request = plan.request
      if requestCase.operation == .urlTemplateCompilation {
        guard let stimulus = input.urlTemplates[requestCase.id] else {
          throw SourcePipelineConformanceError.inputRouteMismatch
        }
        let compilation = try urlTemplateCompilation(
          fixture,
          input: stimulus
        )
        requestPlan.append(HTTPRequestEnvelope(request: request))
        cases.append(
          urlTemplateCase(
            requestCase,
            compilation: compilation
          )
        )
        continue
      }
      if requestCase.operation == .fieldEncoding {
        guard let stimulus = input.fieldEncodings[requestCase.id] else {
          throw SourcePipelineConformanceError.inputRouteMismatch
        }
        requestPlan.append(HTTPRequestEnvelope(request: request))
        cases.append(
          fieldEncodingCase(
            requestCase,
            input: stimulus
          )
        )
        continue
      }
      if requestCase.operation == .rateLimitState {
        guard let stimulus = input.rateLimits[requestCase.id] else {
          throw SourcePipelineConformanceError.inputRouteMismatch
        }
        requestPlan.append(HTTPRequestEnvelope(request: request))
        cases.append(
          try await rateLimitCase(
            requestCase,
            input: stimulus,
            limiter: rateLimiter
          )
        )
        continue
      }
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
        wordCount: optionalRule(search, "wordCount"),
        lastChapter: optionalRule(search, "lastChapter"),
        bookURL: rule(search, "bookUrl"),
        coverURL: optionalRule(search, "coverUrl")
      ),
      bookInfo: BookInfoRules(
        name: rule(bookInfo, "name"),
        author: optionalRule(bookInfo, "author"),
        intro: optionalRule(bookInfo, "intro"),
        kind: optionalRule(bookInfo, "kind"),
        wordCount: optionalRule(bookInfo, "wordCount"),
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
      case .fieldEncoding:
        guard let stimulus = input.fieldEncodings[requestCase.id] else {
          throw SourcePipelineConformanceError.inputRouteMismatch
        }
        plan = fieldEncodingPlan(
          requestCase,
          input: stimulus
        )
      case .urlTemplateCompilation:
        guard let stimulus = input.urlTemplates[requestCase.id] else {
          throw SourcePipelineConformanceError.inputRouteMismatch
        }
        plan = try urlTemplateCompilation(
          fixture,
          input: stimulus
        ).plan
      case .rateLimitState:
        guard input.rateLimits[requestCase.id] != nil else {
          throw SourcePipelineConformanceError.inputRouteMismatch
        }
        plan = SourceRequestPlan(
          request: requestCase.request,
          body: nil,
          formFields: []
        )
      default:
        throw SourcePipelineConformanceError.unsupportedOperation
      }
      plans[requestCase.id] = plan
    }
    return plans
  }

  private static func urlTemplateCompilation(
    _ fixture: LoadedFixture,
    input: SourceURLTemplateInput
  ) throws -> SourceURLTemplateCompilation {
    guard
      let origin = fixture.definition.determinism.logicalOrigin?
        .absoluteString
    else {
      throw SourcePipelineConformanceError.invalidSourceDefinition
    }
    let baseURL = input.basePath.map { origin + $0 } ?? origin
    return try SourceURLTemplateCompiler.compile(
      SourceRuntime.SourceURLTemplateInput(
        template: input.template,
        key: input.key,
        page: input.page,
        baseURL: baseURL
      )
    )
  }

  private static func urlTemplateCase(
    _ requestCase: FixtureRequestCase,
    compilation: SourceURLTemplateCompilation
  ) -> JSONValue {
    let plan = compilation.plan
    return .object([
      "id": .string(requestCase.id),
      "operation": .string(requestCase.operation.rawValue),
      "result": .object([
        "rule_url": .string(compilation.ruleURL),
        "url": .string(compilation.logicalURL),
        "url_no_query": .string(compilation.logicalURLNoQuery),
        "method": .string(plan.request.method.rawValue),
        "body": plan.body.map(JSONValue.string) ?? .null,
        "query_string": compilation.queryString.map(JSONValue.string) ?? .null,
        "field_map": .array(
          plan.formFields.map { field in
            .object([
              "key": .string(field.key),
              "value": .string(field.value),
            ])
          }
        ),
        "retry": .number(JSONNumber(Int64(plan.retry))),
      ]),
      "issue": .null,
    ])
  }

  private static func fieldEncodingPlan(
    _ requestCase: FixtureRequestCase,
    input: SourceFieldEncodingInput
  ) -> SourceRequestPlan {
    guard input.method == requestCase.request.method else {
      return SourceRequestPlan(
        request: requestCase.request,
        body: nil,
        formFields: []
      )
    }
    do {
      let fields = try SourceFieldCompiler.compile(
        input.fields,
        charset: input.charset
      )
      let encoded =
        fields
        .map { "\($0.key)=\($0.value)" }
        .joined(separator: "&")
      switch input.method {
      case .get:
        return SourceRequestPlan(
          request: HTTPRequest(
            method: .get,
            url: try HTTPURL(
              requestCase.request.url.absoluteString + "?" + encoded
            )
          ),
          body: nil,
          formFields: fields
        )
      case .post:
        return SourceRequestPlan(
          request: HTTPRequest(
            method: .post,
            url: requestCase.request.url,
            body: HTTPBody(Data(encoded.utf8))
          ),
          body: encoded,
          formFields: fields
        )
      }
    } catch {
      return SourceRequestPlan(
        request: HTTPRequest(
          method: input.method,
          url: requestCase.request.url
        ),
        body: nil,
        formFields: []
      )
    }
  }

  private static func fieldEncodingCase(
    _ requestCase: FixtureRequestCase,
    input: SourceFieldEncodingInput
  ) -> JSONValue {
    do {
      let fields = try SourceFieldCompiler.compile(
        input.fields,
        charset: input.charset
      )
      return .object([
        "id": .string(requestCase.id),
        "operation": .string(requestCase.operation.rawValue),
        "result": .object([
          "field_map": .array(
            fields.map { field in
              .object([
                "key": .string(field.key),
                "value": .string(field.value),
              ])
            }
          ),
          "method": .string(input.method.rawValue),
          "query_string": .string(input.fields),
        ]),
        "issue": .null,
      ])
    } catch {
      return .object([
        "id": .string(requestCase.id),
        "operation": .string(requestCase.operation.rawValue),
        "result": .null,
        "issue": .object([
          "code": .string("rule_failed"),
          "stage": .string("field_evaluation"),
        ]),
      ])
    }
  }

  private static func rateLimitCase(
    _ requestCase: FixtureRequestCase,
    input: SourceRateLimitInput,
    limiter: SourceRateLimiter
  ) async throws -> JSONValue {
    let id = requestCase.id
    let result: JSONValue

    switch input.mode {
    case "disabled":
      let start = await limiter.start(
        sourceKey: id,
        concurrentRate: input.concurrentRate
      )
      result = .object([
        "active": .bool(start.isActive),
        "rate": .string(input.concurrentRate),
      ])

    case "interval_shared":
      let first = await limiter.start(
        sourceKey: id,
        concurrentRate: input.concurrentRate
      )
      let second = await limiter.start(
        sourceKey: id,
        concurrentRate: input.concurrentRate
      )
      guard
        let firstPermit = first.permit,
        let frequency = second.state?.frequency
      else {
        throw SourcePipelineConformanceError.invalidSourceDefinition
      }
      await limiter.finish(firstPermit)
      let afterEnd = await limiter.start(
        sourceKey: id,
        concurrentRate: input.concurrentRate
      )
      result = .object([
        "first_allowed": .bool(first.isAllowed),
        "second_same_key_denied": .bool(
          !second.isAllowed && second.waitMilliseconds > 0
        ),
        "after_end_still_denied": .bool(
          !afterEnd.isAllowed && afterEnd.waitMilliseconds > 0
        ),
        "record_mode": .string(SourceRateLimitMode.minimumInterval.rawValue),
        "frequency_on_denial": .number(JSONNumber(Int64(frequency))),
      ])

    case "window_boundary":
      var allowed = 0
      var deniedWait: Int64 = 0
      var frequency = 0
      for _ in 0..<4 {
        let start = await limiter.start(
          sourceKey: id,
          concurrentRate: input.concurrentRate
        )
        if start.isAllowed {
          allowed += 1
        } else {
          deniedWait = start.waitMilliseconds
        }
        frequency = start.state?.frequency ?? frequency
      }
      result = .object([
        "allowed_before_denial": .number(JSONNumber(Int64(allowed))),
        "denied_wait_positive": .bool(deniedWait > 0),
        "record_mode": .string(SourceRateLimitMode.countPerWindow.rawValue),
        "frequency_on_denial": .number(JSONNumber(Int64(frequency))),
      ])

    case "distinct_keys":
      let first = await limiter.start(
        sourceKey: "\(id)-a",
        concurrentRate: input.concurrentRate
      )
      let second = await limiter.start(
        sourceKey: "\(id)-b",
        concurrentRate: input.concurrentRate
      )
      result = .object([
        "both_allowed": .bool(first.isAllowed && second.isAllowed),
        "records_are_distinct": .bool(
          first.state?.sourceKey != second.state?.sourceKey
        ),
      ])

    case "invalid_degrades":
      let first = await limiter.start(
        sourceKey: id,
        concurrentRate: input.concurrentRate
      )
      let second = await limiter.start(
        sourceKey: id,
        concurrentRate: input.concurrentRate
      )
      guard
        let firstState = first.state,
        let secondState = second.state
      else {
        throw SourcePipelineConformanceError.invalidSourceDefinition
      }
      result = .object([
        "both_allowed": .bool(first.isAllowed && second.isAllowed),
        "same_record": .bool(
          firstState.sourceKey == secondState.sourceKey
            && firstState.startedAtMilliseconds
              == secondState.startedAtMilliseconds
        ),
        "is_count_window": .bool(
          firstState.mode == .countPerWindow
        ),
        "frequency_after_second": .number(
          JSONNumber(Int64(secondState.frequency))
        ),
      ])

    default:
      throw SourcePipelineConformanceError.invalidSourceDefinition
    }

    return .object([
      "id": .string(id),
      "operation": .string(requestCase.operation.rawValue),
      "result": result,
      "issue": .null,
    ])
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

private struct SourceConformanceFixedClock: SourceRateLimitClock {
  let milliseconds: Int64

  func nowMilliseconds() -> Int64 {
    milliseconds
  }
}
