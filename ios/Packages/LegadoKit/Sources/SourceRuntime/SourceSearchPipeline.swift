import Foundation

public struct SourceSearchDefinition: Sendable, Equatable {
  public let sourceURL: String
  public let sourceName: String
  public let originOrder: Int
  public let bookURLPattern: String?
  public let runtime: HTMLCSSSourceDefinition

  public init(
    sourceURL: String,
    sourceName: String,
    originOrder: Int,
    bookURLPattern: String? = nil,
    runtime: HTMLCSSSourceDefinition
  ) {
    self.sourceURL = sourceURL
    self.sourceName = sourceName
    self.originOrder = originOrder
    self.bookURLPattern = bookURLPattern
    self.runtime = runtime
  }
}

public struct SourceSearchInput: Sendable, Equatable {
  public let keyword: String
  public let page: Int

  public init(keyword: String, page: Int) {
    self.keyword = keyword
    self.page = page
  }
}

public struct SourceSearchResponse: Sendable, Equatable {
  public let url: String
  public let body: String

  public init(url: String, body: String) {
    self.url = url
    self.body = body
  }
}

public protocol SourceSearchResponseChecking: Sendable {
  func check(
    _ response: SourceSearchResponse,
    source: SourceSearchDefinition,
    input: SourceSearchInput
  ) async throws -> SourceSearchResponse
}

public struct IdentitySourceSearchResponseChecker:
  SourceSearchResponseChecking
{
  public init() {}

  public func check(
    _ response: SourceSearchResponse,
    source: SourceSearchDefinition,
    input: SourceSearchInput
  ) async throws -> SourceSearchResponse {
    response
  }
}

public struct SourceSearchBook: Sendable, Equatable {
  public let name: String
  public let author: String
  public let kind: String
  public let wordCount: String
  public let intro: String
  public let lastChapter: String
  public let bookURL: String
  public let coverURL: String?
  public let origin: String
  public let originName: String
  public let originOrder: Int
  public let infoHTML: String?

  public init(
    name: String,
    author: String,
    kind: String,
    wordCount: String,
    intro: String,
    lastChapter: String,
    bookURL: String,
    coverURL: String?,
    origin: String,
    originName: String,
    originOrder: Int,
    infoHTML: String?
  ) {
    self.name = name
    self.author = author
    self.kind = kind
    self.wordCount = wordCount
    self.intro = intro
    self.lastChapter = lastChapter
    self.bookURL = bookURL
    self.coverURL = coverURL
    self.origin = origin
    self.originName = originName
    self.originOrder = originOrder
    self.infoHTML = infoHTML
  }
}

public struct SourceSearchExecution: Sendable, Equatable {
  public let requestPlan: SourceRequestPlan
  public let response: SourceSearchResponse
  public let books: [SourceSearchBook]

  public init(
    requestPlan: SourceRequestPlan,
    response: SourceSearchResponse,
    books: [SourceSearchBook]
  ) {
    self.requestPlan = requestPlan
    self.response = response
    self.books = books
  }
}

public enum SourceSearchPipelineError: Error, Sendable, Equatable {
  case invalidResponseEncoding
}

public struct SourceSearchPipeline: Sendable {
  private let definition: SourceSearchDefinition
  private let transport: any HTTPTransport
  private let responseChecker: any SourceSearchResponseChecking

  public init(
    definition: SourceSearchDefinition,
    transport: any HTTPTransport,
    responseChecker: any SourceSearchResponseChecking =
      IdentitySourceSearchResponseChecker()
  ) {
    self.definition = definition
    self.transport = transport
    self.responseChecker = responseChecker
  }

  public func search(_ input: SourceSearchInput) async throws
    -> SourceSearchExecution
  {
    guard
      !definition.runtime.searchURLTemplate
        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw SourceRuntimeIssue(
        stage: .fieldEvaluation,
        code: .ruleFailed
      )
    }

    let compilation = try SourceURLTemplateCompiler.compile(
      SourceURLTemplateInput(
        template: definition.runtime.searchURLTemplate,
        key: input.keyword,
        page: input.page,
        baseURL: definition.sourceURL
      )
    )
    let networkResponse = try await transport.execute(
      compilation.plan.request
    )
    guard
      let body = String(
        data: networkResponse.body.bytes,
        encoding: .utf8
      )
    else {
      throw SourceSearchPipelineError.invalidResponseEncoding
    }
    let checked = try await responseChecker.check(
      SourceSearchResponse(
        url: networkResponse.effectiveURL.absoluteString,
        body: body
      ),
      source: definition,
      input: input
    )
    let books = try parse(response: checked)
    return SourceSearchExecution(
      requestPlan: compilation.plan,
      response: checked,
      books: books
    )
  }

  private func parse(
    response: SourceSearchResponse
  ) throws -> [SourceSearchBook] {
    try SourceBookListParser(definition: definition).parse(
      response: response,
      rules: definition.runtime.search,
      reverse: false,
      allowsDetailPattern: true
    )
  }
}
