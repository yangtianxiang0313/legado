import Foundation
import LibraryDomain
import RuleRuntime
import SourceRuntime

public protocol BookInfoLoading: Sendable {
  func load(book: ShelfBookItem) async throws -> ShelfBookCandidate
}

public struct SourceBookInfoLoader: BookInfoLoading, Sendable {
  private let sources: [SearchSourceDescriptor]
  private let transport: any HTTPTransport
  private let cookieStore: SourceCookieStore
  private let dynamicWebPagePort: (any SourceDynamicWebPagePort)?
  private let scriptRuntime: (any SourceScriptRuntime)?
  private let htmlSelectorBackend: (any HTMLSelectorBackend)?

  public init(
    sources: [SearchSourceDescriptor],
    transport: any HTTPTransport,
    cookieStore: SourceCookieStore = SourceCookieStore(),
    dynamicWebPagePort: (any SourceDynamicWebPagePort)? = nil,
    scriptRuntime: (any SourceScriptRuntime)? = nil,
    htmlSelectorBackend: (any HTMLSelectorBackend)? = nil
  ) {
    self.sources = sources
    self.transport = transport
    self.cookieStore = cookieStore
    self.dynamicWebPagePort = dynamicWebPagePort
    self.scriptRuntime = scriptRuntime
    self.htmlSelectorBackend = htmlSelectorBackend
  }

  public func load(
    book: ShelfBookItem
  ) async throws -> ShelfBookCandidate {
    let candidate = book.candidate
    guard
      let source = sources.first(where: {
        $0.id == candidate.sourceID
          || $0.definition.sourceURL == candidate.sourceID
      }),
      let sourceURL = URL(string: source.definition.sourceURL)
    else {
      throw ChapterTOCFailure.missingSource
    }
    let bookEndpoint = try SourceEndpoint(
      resolving: candidate.bookRequestExpression,
      relativeTo: sourceURL
    )
    let tocEndpoint = try candidate.tocURL.map {
      try SourceEndpoint(resolving: $0, relativeTo: sourceURL)
    }
    let execution = try await SourceBookInfoPipeline(
      definition: source.definition,
      transport: transport,
      cookieStore: cookieStore,
      dynamicWebPagePort: dynamicWebPagePort,
      scriptRuntime: scriptRuntime,
      htmlSelectorBackend: htmlSelectorBackend
    ).load(
      book: SourceBook(
        name: candidate.name,
        author: candidate.author,
        intro: candidate.intro,
        kind: candidate.kind,
        lastChapter: candidate.lastChapter,
        bookEndpoint: bookEndpoint,
        coverURL: candidate.coverURL.flatMap(URL.init(string:)),
        tocEndpoint: tocEndpoint,
        variables: candidate.variables
      )
    )
    let refreshed = execution.book
    return ShelfBookCandidate(
      name: refreshed.name,
      author: refreshed.author ?? candidate.author,
      kind: refreshed.kind ?? candidate.kind,
      lastChapter: refreshed.lastChapter ?? candidate.lastChapter,
      intro: refreshed.intro ?? candidate.intro,
      bookURL: refreshed.bookURL.absoluteString,
      tocURL: refreshed.tocURL?.absoluteString,
      bookRequestExpression:
        refreshed.bookEndpoint.requestExpression,
      coverURL:
        refreshed.coverURL?.absoluteString ?? candidate.coverURL,
      customCoverURL: candidate.customCoverURL,
      customIntro: candidate.customIntro,
      originName: source.name,
      sourceID: source.id,
      variables: refreshed.variables
    )
  }
}
