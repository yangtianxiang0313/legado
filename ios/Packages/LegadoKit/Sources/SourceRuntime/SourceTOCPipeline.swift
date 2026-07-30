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
  private let cookieStore: SourceCookieStore
  private let bookInfoResponseChecker:
    any SourceBookInfoResponseChecking

  public init(
    definition: SourceSearchDefinition,
    transport: any HTTPTransport,
    cookieStore: SourceCookieStore = SourceCookieStore(),
    bookInfoResponseChecker: any SourceBookInfoResponseChecking =
      IdentitySourceBookInfoResponseChecker()
  ) {
    self.definition = definition
    self.transport = transport
    self.cookieStore = cookieStore
    self.bookInfoResponseChecker = bookInfoResponseChecker
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

  public func chapters(
    book: SourceBook,
    infoHTML: String? = nil,
    canRename: Bool = true
  ) async throws -> SourceTOCExecution {
    let runtime = HTMLCSSSourceRuntime(definition: definition.runtime)
    let detail = try await SourceBookInfoPipeline(
      definition: definition,
      transport: transport,
      cookieStore: cookieStore,
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

    var requests = detail.requestPlan.map { [$0.request] } ?? []
    if let tocHTML = detail.tocHTML {
      return SourceTOCExecution(
        requests: requests,
        book: detail.book,
        chapters: try runtime.chapters(
          html: tocHTML,
          tocEndpoint: tocEndpoint
        )
      )
    }

    let tocPlan = try definition.prepare(
      tocEndpoint.requestPlan()
    )
    requests.append(tocPlan.request)
    let tocResponse = try await SourceRequestSession(
      transport: transport,
      cookieStore: cookieStore
    ).execute(
      tocPlan,
      enabledCookieJar: definition.enabledCookieJar
    ).response
    let tocResponseURL = try responseURL(tocResponse)
    let tocHTML = try responseBody(tocResponse)
    let chapters = try runtime.chapters(
      html: tocHTML,
      tocEndpoint: .plain(tocResponseURL)
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
