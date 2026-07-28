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

public enum SourcePipelineConformanceRunner {
  public static func run(_ fixture: LoadedFixture) async throws -> Data {
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

    for requestCase in fixture.requestCases {
      let request = try compiledRequest(
        for: requestCase,
        runtime: runtime
      )
      guard
        request.method == requestCase.request.method,
        request.url == requestCase.request.url
      else {
        throw SourcePipelineConformanceError.inputRouteMismatch
      }

      let response = try await transport.execute(request)
      guard response.statusCode < 400 else {
        // Android's protected portable projection contains only cases for which
        // the characterization runner reached source parsing. HTTP failures stay
        // covered by the generic transport transcript and are not fabricated here.
        continue
      }
      requestPlan.append(HTTPRequestEnvelope(request: request))
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

    let envelope = ExecutionEnvelope(
      fixtureID: fixture.definition.id,
      engine: ExecutionEngine(
        platform: .ios,
        revision: "conformance-source-runtime-html-css-v1",
        compatibilityProfile: fixture.definition.compatibilityProfile
      ),
      requestPlan: requestPlan,
      decode: nil,
      stages: [],
      result: ExecutionResult(
        type: "source_pipeline",
        value: .object([
          "portable_known_projection": .object([
            "cases": .array(cases)
          ])
        ])
      ),
      issues: []
    )
    return try ExecutionEnvelopeCodec.artifactData(envelope)
  }

  private static func definition(from data: Data) throws -> HTMLCSSSourceDefinition {
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
        author: rule(search, "author"),
        intro: rule(search, "intro"),
        kind: rule(search, "kind"),
        lastChapter: rule(search, "lastChapter"),
        bookURL: rule(search, "bookUrl"),
        coverURL: rule(search, "coverUrl")
      ),
      bookInfo: BookInfoRules(
        name: rule(bookInfo, "name"),
        author: rule(bookInfo, "author"),
        intro: rule(bookInfo, "intro"),
        kind: rule(bookInfo, "kind"),
        lastChapter: rule(bookInfo, "lastChapter"),
        coverURL: rule(bookInfo, "coverUrl"),
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

  private static func compiledRequest(
    for requestCase: FixtureRequestCase,
    runtime: HTMLCSSSourceRuntime
  ) throws -> HTTPRequest {
    switch requestCase.operation {
    case .search:
      guard
        let components = URLComponents(string: requestCase.request.url.absoluteString),
        let keyword = components.queryItems?.first(where: { $0.name == "q" })?.value
      else {
        throw SourcePipelineConformanceError.inputRouteMismatch
      }
      return try runtime.searchRequest(keyword: keyword)
    case .bookInfo, .chapters, .content:
      guard let url = URL(string: requestCase.request.url.absoluteString) else {
        throw SourcePipelineConformanceError.inputRouteMismatch
      }
      return try runtime.request(for: url)
    default:
      throw SourcePipelineConformanceError.unsupportedOperation
    }
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

  private static func searchBookValue(_ book: SourceBook) -> JSONValue {
    .object([
      "name": .string(book.name),
      "author": optional(book.author),
      "intro": optional(book.intro),
      "kind": optional(book.kind),
      "last_chapter": optional(book.lastChapter),
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
