import Foundation

public struct SourceSearchDefinition: Sendable, Equatable {
  public let sourceURL: String
  public let sourceName: String
  public let originOrder: Int
  public let bookURLPattern: String?
  public let sourceHeaders: [SourceHeaderField]
  public let enabledCookieJar: Bool
  public let loginCheckScript: String?
  public let scriptLibrary: SourceScriptLibrary?
  public let sourceUserVariable: String
  public let runtime: HTMLCSSSourceDefinition

  public init(
    sourceURL: String,
    sourceName: String,
    originOrder: Int,
    bookURLPattern: String? = nil,
    sourceHeaders: [SourceHeaderField] = [],
    enabledCookieJar: Bool = false,
    loginCheckScript: String? = nil,
    scriptLibrary: SourceScriptLibrary? = nil,
    sourceUserVariable: String = "",
    runtime: HTMLCSSSourceDefinition
  ) {
    self.sourceURL = sourceURL
    self.sourceName = sourceName
    self.originOrder = originOrder
    self.bookURLPattern = bookURLPattern
    self.sourceHeaders = sourceHeaders
    self.enabledCookieJar = enabledCookieJar
    self.loginCheckScript = loginCheckScript
    self.scriptLibrary = scriptLibrary
    self.sourceUserVariable = sourceUserVariable
    self.runtime = runtime
  }

  func prepare(_ plan: SourceRequestPlan) throws -> SourceRequestPlan {
    let optionHeaders: [SourceHeaderField]
    if !plan.optionHeaders.isEmpty {
      optionHeaders = plan.optionHeaders
    } else {
      optionHeaders = try plan.request.headers.fields.map {
        try SourceHeaderField(name: $0.name, value: $0.value)
      }
    }
    let prepared = try SourceRequestPreparer.prepare(
      request: plan.request,
      inheritedHeaders: sourceHeaders,
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
      useWebView: plan.useWebView,
      webJS: plan.webJS
    )
  }

  func prepare(_ request: HTTPRequest) throws -> HTTPRequest {
    try prepare(
      SourceRequestPlan(
        request: request,
        body: request.body.map {
          String(decoding: $0.bytes, as: UTF8.self)
        },
        formFields: []
      )
    ).request
  }
}

public struct SourceSearchInput: Sendable, Equatable {
  public let keyword: String
  public let page: Int

  public init(keyword: String, page: Int) {
    self.keyword = keyword
    self.page = page
  }
}

public struct SourceSearchResponse: Sendable, Equatable {
  public let url: String
  public let body: String

  public init(url: String, body: String) {
    self.url = url
    self.body = body
  }
}

public protocol SourceSearchResponseChecking: Sendable {
  func check(
    _ response: SourceSearchResponse,
    source: SourceSearchDefinition,
    input: SourceSearchInput
  ) async throws -> SourceSearchResponse
}

public struct IdentitySourceSearchResponseChecker:
  SourceSearchResponseChecking
{
  public init() {}

  public func check(
    _ response: SourceSearchResponse,
    source: SourceSearchDefinition,
    input: SourceSearchInput
  ) async throws -> SourceSearchResponse {
    response
  }
}

public struct SourceSearchBook: Sendable, Equatable {
  public let name: String
  public let author: String
  public let kind: String
  public let wordCount: String
  public let intro: String
  public let lastChapter: String
  public let bookURL: String
  public let bookRequestExpression: String
  public let coverURL: String?
  public let origin: String
  public let originName: String
  public let originOrder: Int
  public let infoHTML: String?
  public let variables: [String: String]

  public init(
    name: String,
    author: String,
    kind: String,
    wordCount: String,
    intro: String,
    lastChapter: String,
    bookURL: String,
    bookRequestExpression: String? = nil,
    coverURL: String?,
    origin: String,
    originName: String,
    originOrder: Int,
    infoHTML: String?,
    variables: [String: String] = [:]
  ) {
    self.name = name
    self.author = author
    self.kind = kind
    self.wordCount = wordCount
    self.intro = intro
    self.lastChapter = lastChapter
    self.bookURL = bookURL
    self.bookRequestExpression = bookRequestExpression ?? bookURL
    self.coverURL = coverURL
    self.origin = origin
    self.originName = originName
    self.originOrder = originOrder
    self.infoHTML = infoHTML
    self.variables = variables
  }
}

public struct SourceSearchExecution: Sendable, Equatable {
  public let requestPlan: SourceRequestPlan
  public let response: SourceSearchResponse
  public let books: [SourceSearchBook]

  public init(
    requestPlan: SourceRequestPlan,
    response: SourceSearchResponse,
    books: [SourceSearchBook]
  ) {
    self.requestPlan = requestPlan
    self.response = response
    self.books = books
  }
}

public enum SourceSearchPipelineError: Error, Sendable, Equatable {
  case invalidResponseEncoding
}

public struct SourceSearchPipeline: Sendable {
  private let definition: SourceSearchDefinition
  private let transport: any HTTPTransport
  private let cookieStore: SourceCookieStore
  private let responseSession: SourceStringResponseSession
  private let responseChecker: any SourceSearchResponseChecking
  private let scriptRuntime: (any SourceScriptRuntime)?
  private let scriptSessionID: SourceScriptSessionID

  public init(
    definition: SourceSearchDefinition,
    transport: any HTTPTransport,
    cookieStore: SourceCookieStore = SourceCookieStore(),
    dynamicWebPagePort: (any SourceDynamicWebPagePort)? = nil,
    scriptRuntime: (any SourceScriptRuntime)? = nil,
    responseChecker: any SourceSearchResponseChecking =
      IdentitySourceSearchResponseChecker()
  ) {
    self.definition = definition
    self.transport = transport
    self.cookieStore = cookieStore
    self.responseSession = SourceStringResponseSession(
      transport: transport,
      cookieStore: cookieStore,
      dynamicWebPagePort: dynamicWebPagePort
    )
    self.responseChecker = responseChecker
    self.scriptRuntime = scriptRuntime
    self.scriptSessionID = SourceScriptSessionID(
      rawValue: definition.sourceURL
    )
  }

  public func search(_ input: SourceSearchInput) async throws
    -> SourceSearchExecution
  {
    let variableStore = SourceVariableStore(
      policy: .androidRuleData
    )
    guard
      !definition.runtime.searchURLTemplate
        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw SourceRuntimeIssue(
        stage: .fieldEvaluation,
        code: .ruleFailed
      )
    }

    let compilation = try await SourceURLTemplateCompiler.compile(
      SourceURLTemplateInput(
        template: definition.runtime.searchURLTemplate,
        key: input.keyword,
        page: input.page,
        baseURL: definition.sourceURL
      ),
      resolver: SourceVariableResolver(
        role: .url,
        scopes: SourceVariableScopes(
          ruleData: variableStore,
          sourceUserVariable: definition.sourceUserVariable
        )
      )
    )
    let requestPlan = try definition.prepare(compilation.plan)
    let networkResponse = try await responseSession.load(
      requestPlan,
      enabledCookieJar: definition.enabledCookieJar
    )
    let loginChecked = try await SourceLoginCheckEvaluator(
      definition: definition,
      scriptRuntime: scriptRuntime,
      scriptSessionID: scriptSessionID
    ).evaluate(
      networkResponse,
      resolver: SourceVariableResolver(
        role: .rule,
        scopes: SourceVariableScopes(
          ruleData: variableStore,
          sourceUserVariable: definition.sourceUserVariable
        )
      )
    )
    let checked = try await responseChecker.check(
      SourceSearchResponse(
        url: loginChecked.finalURL.absoluteString,
        body: loginChecked.body
      ),
      source: definition,
      input: input
    )
    let books = try await parse(
      response: checked,
      variableStore: variableStore
    )
    return SourceSearchExecution(
      requestPlan: requestPlan,
      response: checked,
      books: books
    )
  }

  private func parse(
    response: SourceSearchResponse,
    variableStore: SourceVariableStore
  ) async throws -> [SourceSearchBook] {
    try await SourceBookListParser(
      definition: definition,
      variableStore: variableStore,
      scriptRuntime: scriptRuntime,
      scriptSessionID: scriptSessionID,
      scriptLibrary: definition.scriptLibrary
    ).parse(
      response: response,
      rules: definition.runtime.search,
      reverse: false,
      allowsDetailPattern: true
    )
  }
}
