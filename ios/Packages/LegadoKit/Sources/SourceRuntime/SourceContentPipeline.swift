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

  public init(
    definition: SourceSearchDefinition,
    transport: any HTTPTransport
  ) {
    self.definition = definition
    self.transport = transport
  }

  public func content(chapterURL: String) async throws
    -> SourceContentExecution
  {
    guard let url = URL(string: chapterURL) else {
      throw SourceRuntimeIssue(stage: .urlTemplate, code: .invalidURL)
    }
    let runtime = HTMLCSSSourceRuntime(definition: definition.runtime)
    let request = try runtime.request(for: url)
    let response = try await transport.execute(request)
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
