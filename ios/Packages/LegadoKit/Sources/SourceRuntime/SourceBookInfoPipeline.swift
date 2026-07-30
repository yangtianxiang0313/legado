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
  private let responseChecker: any SourceBookInfoResponseChecking

  public init(
    definition: SourceSearchDefinition,
    transport: any HTTPTransport,
    cookieStore: SourceCookieStore = SourceCookieStore(),
    responseChecker: any SourceBookInfoResponseChecking =
      IdentitySourceBookInfoResponseChecker()
  ) {
    self.definition = definition
    self.transport = transport
    self.cookieStore = cookieStore
    self.responseChecker = responseChecker
  }

  public func load(
    book: SourceBook,
    infoHTML: String? = nil,
    canRename: Bool = true
  ) async throws -> SourceBookInfoExecution {
    let runtime = HTMLCSSSourceRuntime(definition: definition.runtime)
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
        book.bookEndpoint.requestPlan()
      )
      requestPlan = plan
      let networkResponse = try await SourceRequestSession(
        transport: transport,
        cookieStore: cookieStore
      ).execute(
        plan,
        enabledCookieJar: definition.enabledCookieJar
      ).response
      guard
        let body = String(
          data: networkResponse.body.bytes,
          encoding: .utf8
        ),
        let effectiveURL = URL(
          string: networkResponse.effectiveURL.absoluteString
        )
      else {
        throw SourceSearchPipelineError.invalidResponseEncoding
      }
      response = try await responseChecker.check(
        SourceBookInfoResponse(
          url: effectiveURL,
          body: body
        ),
        source: definition,
        book: book
      )
    }

    let parsed = try runtime.bookInfo(
      html: response.body,
      baseURL: book.bookEndpoint.logicalURL,
      redirectURL: response.url,
      existing: book,
      canRename: canRename
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
