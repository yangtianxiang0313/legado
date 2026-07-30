import Foundation

public struct SourceContentExecution: Sendable, Equatable {
  public let requests: [HTTPRequest]
  public let content: SourceContent

  public var request: HTTPRequest {
    requests[0]
  }

  public init(request: HTTPRequest, content: SourceContent) {
    self.requests = [request]
    self.content = content
  }

  public init(
    requests: [HTTPRequest],
    content: SourceContent
  ) {
    precondition(!requests.isEmpty)
    self.requests = requests
    self.content = content
  }
}

public struct SourceContentPipeline: Sendable {
  private let definition: SourceSearchDefinition
  private let transport: any HTTPTransport
  private let cookieStore: SourceCookieStore
  private let responseSession: SourceStringResponseSession
  private let scriptRuntime: (any SourceScriptRuntime)?
  private let scriptSessionID: SourceScriptSessionID

  public init(
    definition: SourceSearchDefinition,
    transport: any HTTPTransport,
    cookieStore: SourceCookieStore = SourceCookieStore(),
    dynamicWebPagePort: (any SourceDynamicWebPagePort)? = nil,
    scriptRuntime: (any SourceScriptRuntime)? = nil
  ) {
    self.definition = definition
    self.transport = transport
    self.cookieStore = cookieStore
    self.scriptRuntime = scriptRuntime
    self.scriptSessionID = SourceScriptSessionID(
      rawValue: definition.sourceURL
    )
    self.responseSession = SourceStringResponseSession(
      transport: transport,
      cookieStore: cookieStore,
      dynamicWebPagePort: dynamicWebPagePort
    )
  }

  public func content(
    chapterURL: String,
    nextChapterURL: String? = nil,
    bookVariables: [String: String] = [:],
    chapterVariables: [String: String] = [:]
  ) async throws
    -> SourceContentExecution
  {
    guard
      let sourceURL = URL(string: definition.sourceURL)
    else {
      throw SourceRuntimeIssue(stage: .urlTemplate, code: .invalidURL)
    }
    let endpoint = try SourceEndpoint(
      resolving: chapterURL,
      relativeTo: sourceURL
    )
    let nextChapterEndpoint = try nextChapterURL.map {
      try SourceEndpoint(resolving: $0, relativeTo: sourceURL)
    }
    return try await content(
      endpoint: endpoint,
      nextChapterEndpoint: nextChapterEndpoint,
      bookVariables: bookVariables,
      chapterVariables: chapterVariables
    )
  }

  public func content(
    endpoint: SourceEndpoint,
    nextChapterEndpoint: SourceEndpoint? = nil,
    bookVariables: [String: String] = [:],
    chapterVariables: [String: String] = [:]
  ) async throws
    -> SourceContentExecution
  {
    let runtime = HTMLCSSSourceRuntime(
      definition: definition.runtime,
      scriptRuntime: scriptRuntime,
      scriptSessionID: scriptSessionID
    )
    let first = try await fetchPage(
      endpoint: endpoint,
      runtime: runtime,
      bookVariables: bookVariables,
      chapterVariables: chapterVariables
    )
    var requests = [first.request]
    var contents = [first.page.content.content]
    var currentChapterVariables =
      first.page.content.variables
    var visited = Set([endpoint.requestExpression])
    if first.page.nextEndpoints.count == 1 {
      var next = first.page.nextEndpoints.first
      while
        let pageEndpoint = next,
        pageEndpoint.logicalURL
          != nextChapterEndpoint?.logicalURL,
        visited.insert(
          pageEndpoint.requestExpression
        ).inserted
      {
        let fetched = try await fetchPage(
          endpoint: pageEndpoint,
          runtime: runtime,
          bookVariables: bookVariables,
          chapterVariables: currentChapterVariables
        )
        requests.append(fetched.request)
        contents.append(fetched.page.content.content)
        currentChapterVariables =
          fetched.page.content.variables
        next = fetched.page.nextEndpoints.first
      }
    } else {
      for pageEndpoint in first.page.nextEndpoints
      where
        pageEndpoint.logicalURL
          != nextChapterEndpoint?.logicalURL
        && visited.insert(
          pageEndpoint.requestExpression
        ).inserted
      {
        let fetched = try await fetchPage(
          endpoint: pageEndpoint,
          runtime: runtime,
          bookVariables: bookVariables,
          chapterVariables: currentChapterVariables
        )
        requests.append(fetched.request)
        contents.append(fetched.page.content.content)
        currentChapterVariables =
          fetched.page.content.variables
      }
    }
    return SourceContentExecution(
      requests: requests,
      content: SourceContent(
        chapterURL: first.page.content.chapterURL,
        content: contents.joined(separator: "\n"),
        variables: currentChapterVariables
      )
    )
  }

  private func fetchPage(
    endpoint: SourceEndpoint,
    runtime: HTMLCSSSourceRuntime,
    bookVariables: [String: String],
    chapterVariables: [String: String]
  ) async throws -> (
    request: HTTPRequest,
    page: SourceContentPage
  ) {
    let bookStore = SourceVariableStore(values: bookVariables)
    let chapterStore = SourceVariableStore(values: chapterVariables)
    let plan = try definition.prepare(
      await endpoint.requestPlan(
        resolver: SourceVariableResolver(
          role: .url,
          scopes: SourceVariableScopes(
            chapter: chapterStore,
            ruleData: bookStore
          )
        )
      )
    )
    let response = try await responseSession.load(
      plan,
      enabledCookieJar: definition.enabledCookieJar,
      javaScript: definition.runtime.content.webJS,
      sourceRegex: definition.runtime.content.sourceRegex
    )
    guard
      let effectiveURL = URL(
        string: response.finalURL.absoluteString
      )
    else {
      throw SourceSearchPipelineError.invalidResponseEncoding
    }
    return (
      plan.request,
      try await runtime.contentPage(
        html: response.body,
        chapterEndpoint: .plain(effectiveURL),
        bookVariables: await bookStore.snapshot(),
        chapterVariables: await chapterStore.snapshot()
      )
    )
  }
}
