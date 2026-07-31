import Foundation
import RuleRuntime

public struct SourceTOCExecution: Sendable, Equatable {
  public let requests: [HTTPRequest]
  public let book: SourceBook
  public let chapters: [SourceChapter]

  public init(
    requests: [HTTPRequest],
    book: SourceBook,
    chapters: [SourceChapter]
  ) {
    self.requests = requests
    self.book = book
    self.chapters = chapters
  }
}

public struct SourceTOCPipeline: Sendable {
  private let definition: SourceSearchDefinition
  private let transport: any HTTPTransport
  private let cookieStore: SourceCookieStore
  private let dynamicWebPagePort: (any SourceDynamicWebPagePort)?
  private let responseSession: SourceStringResponseSession
  private let scriptRuntime: (any SourceScriptRuntime)?
  private let scriptSessionID: SourceScriptSessionID
  private let htmlSelectorBackend: (any HTMLSelectorBackend)?
  private let bookInfoResponseChecker:
    any SourceBookInfoResponseChecking

  public init(
    definition: SourceSearchDefinition,
    transport: any HTTPTransport,
    cookieStore: SourceCookieStore = SourceCookieStore(),
    dynamicWebPagePort: (any SourceDynamicWebPagePort)? = nil,
    scriptRuntime: (any SourceScriptRuntime)? = nil,
    htmlSelectorBackend: (any HTMLSelectorBackend)? = nil,
    bookInfoResponseChecker: any SourceBookInfoResponseChecking =
      IdentitySourceBookInfoResponseChecker()
  ) {
    self.definition = definition
    self.transport = transport
    self.cookieStore = cookieStore
    self.dynamicWebPagePort = dynamicWebPagePort
    self.responseSession = SourceStringResponseSession(
      transport: transport,
      cookieStore: cookieStore,
      dynamicWebPagePort: dynamicWebPagePort
    )
    self.bookInfoResponseChecker = bookInfoResponseChecker
    self.scriptRuntime = scriptRuntime
    self.htmlSelectorBackend = htmlSelectorBackend
    self.scriptSessionID = SourceScriptSessionID(
      rawValue: definition.sourceURL
    )
  }

  public func chapters(bookURL: String) async throws -> SourceTOCExecution {
    guard let sourceURL = URL(string: definition.sourceURL) else {
      throw SourceRuntimeIssue(stage: .urlTemplate, code: .invalidURL)
    }
    let requestedBookEndpoint = try SourceEndpoint(
      resolving: bookURL,
      relativeTo: sourceURL
    )
    return try await chapters(
      book: SourceBook(
        name: "",
        author: nil,
        intro: nil,
        kind: nil,
        lastChapter: nil,
        bookEndpoint: requestedBookEndpoint,
        coverURL: nil,
        tocEndpoint: nil
      )
    )
  }

  /// Starts at a known TOC endpoint without interpreting it as a book detail
  /// page. Android source debug uses this path for the `++` input prefix.
  public func chapters(tocURL: String) async throws -> SourceTOCExecution {
    guard let sourceURL = URL(string: definition.sourceURL) else {
      throw SourceRuntimeIssue(stage: .urlTemplate, code: .invalidURL)
    }
    let endpoint = try SourceEndpoint(
      resolving: tocURL,
      relativeTo: sourceURL
    )
    let book = SourceBook(
      name: "",
      author: nil,
      intro: nil,
      kind: nil,
      lastChapter: nil,
      bookEndpoint: endpoint,
      coverURL: nil,
      tocEndpoint: endpoint
    )
    return try await chapters(
      resolvedBook: book,
      tocEndpoint: endpoint,
      tocHTML: nil,
      initialRequests: []
    )
  }

  public func chapters(
    book: SourceBook,
    infoHTML: String? = nil,
    canRename: Bool = true
  ) async throws -> SourceTOCExecution {
    let detail = try await SourceBookInfoPipeline(
      definition: definition,
      transport: transport,
      cookieStore: cookieStore,
      dynamicWebPagePort: dynamicWebPagePort,
      scriptRuntime: scriptRuntime,
      htmlSelectorBackend: htmlSelectorBackend,
      responseChecker: bookInfoResponseChecker
    ).load(
      book: book,
      infoHTML: infoHTML,
      canRename: canRename
    )
    guard let tocEndpoint = detail.book.tocEndpoint else {
      throw SourceRuntimeIssue(
        stage: .fieldEvaluation,
        code: .ruleFailed
      )
    }
    return try await chapters(
      resolvedBook: detail.book,
      tocEndpoint: tocEndpoint,
      tocHTML: detail.tocHTML,
      initialRequests: detail.requestPlan.map { [$0.request] } ?? []
    )
  }

  private func chapters(
    resolvedBook: SourceBook,
    tocEndpoint: SourceEndpoint,
    tocHTML: String?,
    initialRequests: [HTTPRequest]
  ) async throws -> SourceTOCExecution {
    let runtime = HTMLCSSSourceRuntime(
      definition: definition.runtime,
      scriptRuntime: scriptRuntime,
      scriptSessionID: scriptSessionID,
      scriptLibrary: definition.scriptLibrary,
      sourceUserVariable: definition.sourceUserVariable,
      htmlSelectorBackend: htmlSelectorBackend
    )
    let variableStore = SourceVariableStore(
      policy: .androidRuleData,
      values: resolvedBook.variables
    )

    var requests = initialRequests
    let firstPage: SourceTOCPage
    if let tocHTML {
      firstPage = try await runtime.chapterPage(
        html: tocHTML,
        tocEndpoint: tocEndpoint,
        variableStore: variableStore
      )
    } else {
      let fetched = try await fetchPage(
        endpoint: tocEndpoint,
        runtime: runtime,
        variableStore: variableStore
      )
      requests.append(fetched.request)
      firstPage = fetched.page
    }

    var chapters = firstPage.chapters
    var visited = Set([tocEndpoint.requestExpression])
    if firstPage.nextEndpoints.count == 1 {
      var next = firstPage.nextEndpoints.first
      while
        let endpoint = next,
        visited.insert(endpoint.requestExpression).inserted
      {
        let fetched = try await fetchPage(
          endpoint: endpoint,
          runtime: runtime,
          variableStore: variableStore
        )
        requests.append(fetched.request)
        chapters.append(contentsOf: fetched.page.chapters)
        next = fetched.page.nextEndpoints.first
      }
    } else {
      for endpoint in firstPage.nextEndpoints
      where visited.insert(endpoint.requestExpression).inserted {
        let fetched = try await fetchPage(
          endpoint: endpoint,
          runtime: runtime,
          variableStore: variableStore
        )
        requests.append(fetched.request)
        chapters.append(contentsOf: fetched.page.chapters)
      }
    }
    chapters = normalized(chapters)
    guard !chapters.isEmpty else {
      throw SourceRuntimeIssue(
        stage: .fieldEvaluation,
        code: .ruleFailed
      )
    }
    return SourceTOCExecution(
      requests: requests,
      book: resolvedBook.replacingVariables(
        await variableStore.snapshot()
      ),
      chapters: chapters
    )
  }

  private func fetchPage(
    endpoint: SourceEndpoint,
    runtime: HTMLCSSSourceRuntime,
    variableStore: SourceVariableStore
  ) async throws -> (request: HTTPRequest, page: SourceTOCPage) {
    let plan = try definition.prepare(
      await endpoint.requestPlan(
        resolver: SourceVariableResolver(
          role: .url,
          scopes: SourceVariableScopes(
            ruleData: variableStore,
            sourceUserVariable: definition.sourceUserVariable
          )
        )
      )
    )
    let networkResponse = try await responseSession.load(
      plan,
      enabledCookieJar: definition.enabledCookieJar
    )
    let response = try await SourceLoginCheckEvaluator(
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
    guard
      let effectiveURL = URL(
        string: response.finalURL.absoluteString
      )
    else {
      throw SourceSearchPipelineError.invalidResponseEncoding
    }
    return (
      plan.request,
      try await runtime.chapterPage(
        html: response.body,
        tocEndpoint: .plain(effectiveURL),
        variableStore: variableStore
      )
    )
  }

  private func normalized(
    _ chapters: [SourceChapter]
  ) -> [SourceChapter] {
    var seen: Set<String> = []
    var result: [SourceChapter] = []
    for chapter in chapters {
      guard
        seen.insert(
          chapter.endpoint.logicalURL.absoluteString
        ).inserted
      else {
        continue
      }
      result.append(
        SourceChapter(
          index: result.count,
          title: chapter.title,
          endpoint: chapter.endpoint,
          isPay: chapter.isPay,
          isVIP: chapter.isVIP,
          isVolume: chapter.isVolume,
          variables: chapter.variables
        )
      )
    }
    return result
  }
}
