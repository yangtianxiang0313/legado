import Foundation

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

  public init(
    definition: SourceSearchDefinition,
    transport: any HTTPTransport
  ) {
    self.definition = definition
    self.transport = transport
  }

  public func chapters(bookURL: String) async throws -> SourceTOCExecution {
    guard let requestedBookURL = URL(string: bookURL) else {
      throw SourceRuntimeIssue(stage: .urlTemplate, code: .invalidURL)
    }
    let runtime = HTMLCSSSourceRuntime(definition: definition.runtime)
    let bookRequest = try runtime.request(for: requestedBookURL)
    let bookResponse = try await transport.execute(bookRequest)
    let bookResponseURL = try responseURL(bookResponse)
    let bookHTML = try responseBody(bookResponse)
    let book = try runtime.bookInfo(
      html: bookHTML,
      bookURL: bookResponseURL
    )
    guard let tocURL = book.tocURL else {
      throw SourceRuntimeIssue(
        stage: .fieldEvaluation,
        code: .ruleFailed
      )
    }

    let tocRequest = try runtime.request(for: tocURL)
    let tocResponse = try await transport.execute(tocRequest)
    let tocResponseURL = try responseURL(tocResponse)
    let tocHTML = try responseBody(tocResponse)
    let chapters = try runtime.chapters(
      html: tocHTML,
      tocURL: tocResponseURL
    )
    return SourceTOCExecution(
      requests: [bookRequest, tocRequest],
      book: book,
      chapters: chapters
    )
  }

  private func responseBody(_ response: HTTPResponse) throws -> String {
    guard let value = String(data: response.body.bytes, encoding: .utf8) else {
      throw SourceSearchPipelineError.invalidResponseEncoding
    }
    return value
  }

  private func responseURL(_ response: HTTPResponse) throws -> URL {
    guard let value = URL(string: response.effectiveURL.absoluteString) else {
      throw SourceRuntimeIssue(stage: .urlTemplate, code: .invalidURL)
    }
    return value
  }
}
