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
    let firstPage: SourceTOCPage
    if let tocHTML = detail.tocHTML {
      firstPage = try runtime.chapterPage(
        html: tocHTML,
        tocEndpoint: tocEndpoint
      )
    } else {
      let fetched = try await fetchPage(
        endpoint: tocEndpoint,
        runtime: runtime
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
          runtime: runtime
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
          runtime: runtime
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
      book: detail.book,
      chapters: chapters
    )
  }

  private func fetchPage(
    endpoint: SourceEndpoint,
    runtime: HTMLCSSSourceRuntime
  ) async throws -> (request: HTTPRequest, page: SourceTOCPage) {
    let plan = try definition.prepare(endpoint.requestPlan())
    let response = try await SourceRequestSession(
      transport: transport,
      cookieStore: cookieStore
    ).execute(
      plan,
      enabledCookieJar: definition.enabledCookieJar
    ).response
    guard
      let body = String(data: response.body.bytes, encoding: .utf8),
      let effectiveURL = URL(
        string: response.effectiveURL.absoluteString
      )
    else {
      throw SourceSearchPipelineError.invalidResponseEncoding
    }
    return (
      plan.request,
      try runtime.chapterPage(
        html: body,
        tocEndpoint: .plain(effectiveURL)
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
          isVolume: chapter.isVolume
        )
      )
    }
    return result
  }
}
