import Foundation

public struct SourceBookInfoResponse: Sendable, Equatable {
  public let url: URL
  public let body: String

  public init(url: URL, body: String) {
    self.url = url
    self.body = body
  }
}

public protocol SourceBookInfoResponseChecking: Sendable {
  func check(
    _ response: SourceBookInfoResponse,
    source: SourceSearchDefinition,
    book: SourceBook
  ) async throws -> SourceBookInfoResponse
}

public struct IdentitySourceBookInfoResponseChecker:
  SourceBookInfoResponseChecking
{
  public init() {}

  public func check(
    _ response: SourceBookInfoResponse,
    source: SourceSearchDefinition,
    book: SourceBook
  ) async throws -> SourceBookInfoResponse {
    response
  }
}

public struct SourceBookInfoExecution: Sendable, Equatable {
  public let requestPlan: SourceRequestPlan?
  public let response: SourceBookInfoResponse
  public let book: SourceBook
  public let tocHTML: String?

  public init(
    requestPlan: SourceRequestPlan?,
    response: SourceBookInfoResponse,
    book: SourceBook,
    tocHTML: String?
  ) {
    self.requestPlan = requestPlan
    self.response = response
    self.book = book
    self.tocHTML = tocHTML
  }
}

public struct SourceBookInfoPipeline: Sendable {
  private let definition: SourceSearchDefinition
  private let transport: any HTTPTransport
  private let cookieStore: SourceCookieStore
  private let responseSession: SourceStringResponseSession
  private let responseChecker: any SourceBookInfoResponseChecking
  private let scriptRuntime: (any SourceScriptRuntime)?
  private let scriptSessionID: SourceScriptSessionID

  public init(
    definition: SourceSearchDefinition,
    transport: any HTTPTransport,
    cookieStore: SourceCookieStore = SourceCookieStore(),
    dynamicWebPagePort: (any SourceDynamicWebPagePort)? = nil,
    scriptRuntime: (any SourceScriptRuntime)? = nil,
    responseChecker: any SourceBookInfoResponseChecking =
      IdentitySourceBookInfoResponseChecker()
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

  public func load(
    book: SourceBook,
    infoHTML: String? = nil,
    canRename: Bool = true
  ) async throws -> SourceBookInfoExecution {
    let runtime = HTMLCSSSourceRuntime(
      definition: definition.runtime,
      scriptRuntime: scriptRuntime,
      scriptSessionID: scriptSessionID
    )
    let variableStore = SourceVariableStore(
      policy: .androidRuleData,
      values: book.variables
    )
    let requestPlan: SourceRequestPlan?
    let response: SourceBookInfoResponse

    if let infoHTML, !infoHTML.isEmpty {
      requestPlan = nil
      response = SourceBookInfoResponse(
        url: book.bookEndpoint.logicalURL,
        body: infoHTML
      )
    } else {
      let plan = try definition.prepare(
        await book.bookEndpoint.requestPlan(
          resolver: SourceVariableResolver(
            role: .url,
            scopes: SourceVariableScopes(
              ruleData: variableStore,
              bookName: book.name
            )
          )
        )
      )
      requestPlan = plan
      let networkResponse = try await responseSession.load(
        plan,
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
            book: variableStore,
            ruleData: variableStore,
            bookName: book.name
          )
        )
      )
      guard
        let effectiveURL = URL(
          string: loginChecked.finalURL.absoluteString
        )
      else {
        throw SourceSearchPipelineError.invalidResponseEncoding
      }
      response = try await responseChecker.check(
        SourceBookInfoResponse(
          url: effectiveURL,
          body: loginChecked.body
        ),
        source: definition,
        book: book
      )
    }

    let parsed = try await runtime.bookInfo(
      html: response.body,
      baseURL: book.bookEndpoint.logicalURL,
      redirectURL: response.url,
      existing: book,
      canRename: canRename,
      variableStore: variableStore
    )
    return SourceBookInfoExecution(
      requestPlan: requestPlan,
      response: response,
      book: parsed,
      tocHTML:
        parsed.tocEndpoint == book.bookEndpoint
        ? response.body
        : nil
    )
  }
}
