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
  private let bookInfoResponseChecker:
    any SourceBookInfoResponseChecking

  public init(
    definition: SourceSearchDefinition,
    transport: any HTTPTransport,
    bookInfoResponseChecker: any SourceBookInfoResponseChecking =
      IdentitySourceBookInfoResponseChecker()
  ) {
    self.definition = definition
    self.transport = transport
    self.bookInfoResponseChecker = bookInfoResponseChecker
  }

  public func chapters(bookURL: String) async throws -> SourceTOCExecution {
    guard let requestedBookURL = URL(string: bookURL) else {
      throw SourceRuntimeIssue(stage: .urlTemplate, code: .invalidURL)
    }
    return try await chapters(
      book: SourceBook(
        name: "",
        author: nil,
        intro: nil,
        kind: nil,
        lastChapter: nil,
        bookURL: requestedBookURL,
        coverURL: nil,
        tocURL: nil
      )
    )
  }

  public func chapters(
    book: SourceBook,
    infoHTML: String? = nil,
    canRename: Bool = true
  ) async throws -> SourceTOCExecution {
    let runtime = HTMLCSSSourceRuntime(definition: definition.runtime)
    let detail = try await SourceBookInfoPipeline(
      definition: definition,
      transport: transport,
      responseChecker: bookInfoResponseChecker
    ).load(
      book: book,
      infoHTML: infoHTML,
      canRename: canRename
    )
    guard let tocURL = detail.book.tocURL else {
      throw SourceRuntimeIssue(
        stage: .fieldEvaluation,
        code: .ruleFailed
      )
    }

    var requests = detail.requestPlan.map { [$0.request] } ?? []
    if let tocHTML = detail.tocHTML {
      return SourceTOCExecution(
        requests: requests,
        book: detail.book,
        chapters: try runtime.chapters(
          html: tocHTML,
          tocURL: tocURL
        )
      )
    }

    let tocRequest = try runtime.request(for: tocURL)
    requests.append(tocRequest)
    let tocResponse = try await transport.execute(tocRequest)
    let tocResponseURL = try responseURL(tocResponse)
    let tocHTML = try responseBody(tocResponse)
    let chapters = try runtime.chapters(
      html: tocHTML,
      tocURL: tocResponseURL
    )
    return SourceTOCExecution(
      requests: requests,
      book: detail.book,
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
