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

public struct DictionaryLookupPipeline: Sendable {
  private let transport: any HTTPTransport
  private let cookieStore: SourceCookieStore
  private let htmlSelectorBackend: (any HTMLSelectorBackend)?
  private let scriptRuntime: (any SourceScriptRuntime)?

  public init(
    transport: any HTTPTransport,
    cookieStore: SourceCookieStore = SourceCookieStore(),
    htmlSelectorBackend: (any HTMLSelectorBackend)? = nil,
    scriptRuntime: (any SourceScriptRuntime)? = nil
  ) {
    self.transport = transport
    self.cookieStore = cookieStore
    self.htmlSelectorBackend = htmlSelectorBackend
    self.scriptRuntime = scriptRuntime
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
}
