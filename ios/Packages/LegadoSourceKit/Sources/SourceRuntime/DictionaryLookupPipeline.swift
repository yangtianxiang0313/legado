import Foundation
import RuleRuntime

public struct DictionaryRuntimeRule: Equatable, Sendable {
  public let name: String
  public let urlRule: String
  public let showRule: String

  public init(name: String, urlRule: String, showRule: String = "") {
    self.name = name
    self.urlRule = urlRule
    self.showRule = showRule
  }
}

public struct DictionaryLookupResult: Equatable, Sendable {
  public let ruleName: String
  public let word: String
  public let content: String
  public let requestPlan: SourceRequestPlan
  public let finalURL: HTTPURL
}

public protocol DictionaryDOMTransforming: Sendable {
  func innerHTML(
    html: String,
    removing selector: String,
    selecting resultSelector: String
  ) throws -> String
}

public struct HTMLSelectorDictionaryDOMTransformer:
  DictionaryDOMTransforming, Sendable
{
  private let backend: any HTMLSelectorBackend

  public init(backend: any HTMLSelectorBackend) {
    self.backend = backend
  }

  public func innerHTML(
    html: String,
    removing selector: String,
    selecting resultSelector: String
  ) throws -> String {
    guard var panel = try backend.select(
      html: html,
      selector: resultSelector
    ).first?.outerHTML else { return "" }
    for unwanted in try backend.select(html: panel, selector: selector) {
      panel = panel.replacingOccurrences(of: unwanted.outerHTML, with: "")
    }
    guard
      let opening = panel.firstIndex(of: ">"),
      let closing = panel.range(of: "</", options: .backwards),
      opening < closing.lowerBound
    else { return panel }
    return String(panel[panel.index(after: opening)..<closing.lowerBound])
  }
}

public struct DictionaryLookupPipeline: Sendable {
  private let transport: any HTTPTransport
  private let cookieStore: SourceCookieStore
  private let htmlSelectorBackend: (any HTMLSelectorBackend)?
  private let scriptRuntime: (any SourceScriptRuntime)?
  private let domTransformer: (any DictionaryDOMTransforming)?

  public init(
    transport: any HTTPTransport,
    cookieStore: SourceCookieStore = SourceCookieStore(),
    htmlSelectorBackend: (any HTMLSelectorBackend)? = nil,
    scriptRuntime: (any SourceScriptRuntime)? = nil,
    domTransformer: (any DictionaryDOMTransforming)? = nil
  ) {
    self.transport = transport
    self.cookieStore = cookieStore
    self.htmlSelectorBackend = htmlSelectorBackend
    self.scriptRuntime = scriptRuntime
    self.domTransformer = domTransformer
  }

  public func lookup(word: String, rule: DictionaryRuntimeRule) async throws
    -> DictionaryLookupResult
  {
    let compilation = try SourceURLTemplateCompiler.compile(
      SourceURLTemplateInput(
        template: rule.urlRule,
        key: word,
        baseURL: rule.urlRule
      )
    )
    let plan = try prepared(compilation.plan)
    let response = try await SourceStringResponseSession(
      transport: transport,
      cookieStore: cookieStore
    ).load(plan, enabledCookieJar: false)
    let content = try await project(
      response.body,
      showRule: rule.showRule,
      ruleName: rule.name
    )
    return DictionaryLookupResult(
      ruleName: rule.name,
      word: word,
      content: content,
      requestPlan: plan,
      finalURL: response.finalURL
    )
  }

  private func prepared(_ plan: SourceRequestPlan) throws -> SourceRequestPlan {
    let optionHeaders = try plan.optionHeaders.isEmpty
      ? plan.request.headers.fields.map {
        try SourceHeaderField(name: $0.name, value: $0.value)
      }
      : plan.optionHeaders
    let prepared = try SourceRequestPreparer.prepare(
      request: plan.request,
      inheritedHeaders: [],
      optionHeaders: optionHeaders,
      persistentCookie: "",
      enabledCookieJar: false,
      retry: plan.retry
    )
    return SourceRequestPlan(
      request: prepared.constructedRequest,
      body: plan.body,
      formFields: plan.formFields,
      optionHeaders: optionHeaders,
      retry: plan.retry,
      useWebView: false,
      webJS: nil
    )
  }

  private func project(
    _ body: String,
    showRule: String,
    ruleName: String
  ) async throws -> String {
    guard !showRule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return body
    }
    guard showRule.lowercased().hasPrefix("@js:") else {
      return try SourceRuleConsumerEvaluator(
        content: body,
        htmlSelectorBackend: htmlSelectorBackend
      ).getString(showRule)
    }
    if Self.isBuiltInBaiduJSoupScript(showRule) {
      guard let domTransformer else {
        throw SourceScriptIssue(code: .capabilityDenied)
      }
      return try domTransformer.innerHTML(
        html: body,
        removing: Self.baiduNoiseSelector,
        selecting: "#content-panel"
      )
    }
    guard let scriptRuntime else {
      throw SourceScriptIssue(code: .capabilityDenied)
    }
    let value = try await scriptRuntime.evaluate(
      SourceScriptRequest(
        sessionID: SourceScriptSessionID(rawValue: "dictionary:\(ruleName)"),
        script: String(showRule.dropFirst(4)),
        result: .string(body)
      ),
      host: nil
    )
    switch value {
    case .undefined, .null: return ""
    case .bool(let value): return String(value)
    case .number(let value): return String(value)
    case .string(let value): return value
    case .array(let values):
      return values.map { String(describing: $0) }.joined(separator: "\n")
    case .object: return ""
    }
  }

  private static let baiduNoiseSelector =
    "script,#word-header,#term-header,.more-button,.disactive,"
    + "#download-wrapper,#upload-dialog,#right-panel,#success-dialog,"
    + ".toast-wrap,div[style^=color],.baike-feedback,"
    + "#cishumean-wrapper,#syn_ant_wrapper,#baike-wrapper"

  private static func isBuiltInBaiduJSoupScript(_ value: String) -> Bool {
    value.contains("org.jsoup.Jsoup.parse(result)")
      && value.contains("jsoup.select(\"#content-panel\").html()")
      && value.contains(".remove()")
  }
}
