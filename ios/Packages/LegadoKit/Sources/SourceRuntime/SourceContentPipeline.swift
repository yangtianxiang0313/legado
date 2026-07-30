import Foundation

public struct SourceContentExecution: Sendable, Equatable {
  public let request: HTTPRequest
  public let content: SourceContent

  public init(request: HTTPRequest, content: SourceContent) {
    self.request = request
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

  public func content(chapterURL: String) async throws
    -> SourceContentExecution
  {
    guard let url = URL(string: chapterURL) else {
      throw SourceRuntimeIssue(stage: .urlTemplate, code: .invalidURL)
    }
    let runtime = HTMLCSSSourceRuntime(definition: definition.runtime)
    let request = try definition.prepare(runtime.request(for: url))
    let response = try await SourceRequestSession(
      transport: transport,
      cookieStore: cookieStore
    ).execute(
      SourceRequestPlan(
        request: request,
        body: nil,
        formFields: []
      ),
      enabledCookieJar: definition.enabledCookieJar
    ).response
    guard
      let effectiveURL = URL(string: response.effectiveURL.absoluteString),
      let html = String(data: response.body.bytes, encoding: .utf8)
    else {
      throw SourceSearchPipelineError.invalidResponseEncoding
    }
    return SourceContentExecution(
      request: request,
      content: try runtime.content(
        html: html,
        chapterURL: effectiveURL
      )
    )
  }
}
