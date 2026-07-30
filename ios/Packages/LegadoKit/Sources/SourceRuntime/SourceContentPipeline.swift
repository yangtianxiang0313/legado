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

  public init(
    definition: SourceSearchDefinition,
    transport: any HTTPTransport,
    cookieStore: SourceCookieStore = SourceCookieStore()
  ) {
    self.definition = definition
    self.transport = transport
    self.cookieStore = cookieStore
  }

  public func content(
    chapterURL: String,
    nextChapterURL: String? = nil
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
      nextChapterEndpoint: nextChapterEndpoint
    )
  }

  public func content(
    endpoint: SourceEndpoint,
    nextChapterEndpoint: SourceEndpoint? = nil
  ) async throws
    -> SourceContentExecution
  {
    let runtime = HTMLCSSSourceRuntime(definition: definition.runtime)
    let first = try await fetchPage(
      endpoint: endpoint,
      runtime: runtime
    )
    var requests = [first.request]
    var contents = [first.page.content.content]
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
          runtime: runtime
        )
        requests.append(fetched.request)
        contents.append(fetched.page.content.content)
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
          runtime: runtime
        )
        requests.append(fetched.request)
        contents.append(fetched.page.content.content)
      }
    }
    return SourceContentExecution(
      requests: requests,
      content: SourceContent(
        chapterURL: first.page.content.chapterURL,
        content: contents.joined(separator: "\n")
      )
    )
  }

  private func fetchPage(
    endpoint: SourceEndpoint,
    runtime: HTMLCSSSourceRuntime
  ) async throws -> (
    request: HTTPRequest,
    page: SourceContentPage
  ) {
    let plan = try definition.prepare(endpoint.requestPlan())
    let response = try await SourceRequestSession(
      transport: transport,
      cookieStore: cookieStore
    ).execute(
      plan,
      enabledCookieJar: definition.enabledCookieJar
    ).response
    guard
      let effectiveURL = URL(
        string: response.effectiveURL.absoluteString
      ),
      let html = String(data: response.body.bytes, encoding: .utf8)
    else {
      throw SourceSearchPipelineError.invalidResponseEncoding
    }
    return (
      plan.request,
      try runtime.contentPage(
        html: html,
        chapterEndpoint: .plain(effectiveURL)
      )
    )
  }
}
