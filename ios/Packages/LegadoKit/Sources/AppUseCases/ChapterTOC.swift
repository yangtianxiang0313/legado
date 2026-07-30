import Foundation
import LibraryDomain
import Observation
import SourceRuntime

public protocol BookChapterLoading: Sendable {
  func load(
    book: ShelfBookItem
  ) async throws -> BookChapterLoadResult
}

public struct BookChapterLoadResult: Equatable, Sendable {
  public let chapters: [LibraryDomain.BookChapter]
  public let bookVariables: [String: String]

  public init(
    chapters: [LibraryDomain.BookChapter],
    bookVariables: [String: String]
  ) {
    self.chapters = chapters
    self.bookVariables = bookVariables
  }
}

public struct SourceBookChapterLoader: BookChapterLoading, Sendable {
  private let sources: [SearchSourceDescriptor]
  private let transport: any HTTPTransport
  private let cookieStore: SourceCookieStore
  private let dynamicWebPagePort: (any SourceDynamicWebPagePort)?
  private let scriptRuntime: (any SourceScriptRuntime)?

  public init(
    sources: [SearchSourceDescriptor],
    transport: any HTTPTransport,
    cookieStore: SourceCookieStore = SourceCookieStore(),
    dynamicWebPagePort: (any SourceDynamicWebPagePort)? = nil,
    scriptRuntime: (any SourceScriptRuntime)? = nil
  ) {
    self.sources = sources
    self.transport = transport
    self.cookieStore = cookieStore
    self.dynamicWebPagePort = dynamicWebPagePort
    self.scriptRuntime = scriptRuntime
  }

  public func load(
    book: ShelfBookItem
  ) async throws -> BookChapterLoadResult {
    let candidate = book.candidate
    guard
      let source = sources.first(where: {
        $0.id == candidate.sourceID
          || $0.definition.sourceURL == candidate.sourceID
      })
    else {
      throw ChapterTOCFailure.missingSource
    }
    guard let sourceURL = URL(string: source.definition.sourceURL) else {
      throw ChapterTOCFailure.fetchFailed
    }
    let execution = try await SourceTOCPipeline(
      definition: source.definition,
      transport: transport,
      cookieStore: cookieStore,
      dynamicWebPagePort: dynamicWebPagePort,
      scriptRuntime: scriptRuntime
    ).chapters(
      book: SourceBook(
        name: candidate.name,
        author: candidate.author,
        intro: candidate.intro,
        kind: candidate.kind,
        lastChapter: candidate.lastChapter,
        bookEndpoint: try SourceEndpoint(
          resolving: candidate.bookRequestExpression,
          relativeTo: sourceURL
        ),
        coverURL: candidate.coverURL.flatMap(URL.init(string:)),
        tocEndpoint: nil,
        variables: candidate.variables
      )
    )
    let chapters = execution.chapters.map {
      LibraryDomain.BookChapter(
        id: LibraryDomain.ChapterID(
          sourceID: source.id,
          chapterURL: $0.url.absoluteString
        ),
        bookID: book.id,
        sourceID: source.id,
        index: $0.index,
        title: $0.title,
        url: $0.url.absoluteString,
        requestExpression: $0.endpoint.requestExpression,
        isPay: $0.isPay,
        isVIP: $0.isVIP,
        isVolume: $0.isVolume,
        variables: $0.variables
      )
    }
    return BookChapterLoadResult(
      chapters: chapters,
      bookVariables: execution.book.variables
    )
  }
}

public enum ChapterTOCLoadingState: Equatable, Sendable {
  case idle
  case loading
  case loaded
  case failed
}

@MainActor
@Observable
public final class ChapterTOCSession {
  public private(set) var chapters: [LibraryDomain.BookChapter] = []
  public private(set) var state: ChapterTOCLoadingState = .idle
  public private(set) var errorMessage: String?

  private let repository: any BookShelfRepository
  private let loader: any BookChapterLoading

  public init(
    repository: any BookShelfRepository,
    loader: any BookChapterLoading
  ) {
    self.repository = repository
    self.loader = loader
  }

  public func load(book: ShelfBookItem, force: Bool = false) async {
    if state == .loading { return }
    state = .loading
    let existing = (try? await repository.chapters(bookID: book.id)) ?? []
    chapters = existing
    if !force, !existing.isEmpty {
      state = .loaded
      errorMessage = nil
      return
    }

    do {
      let fetched = try await loader.load(book: book)
      let update = ChapterTOCUpdatePolicy.shelfUpdate(
        existing: existing,
        fetched: fetched.chapters
      )
      chapters = try await repository.applyTOCUpdate(
        bookID: book.id,
        update: update,
        bookVariables: fetched.bookVariables
      )
      state = update.updateError ? .failed : .loaded
      errorMessage = update.updateError ? "目录为空，已保留原目录" : nil
    } catch let failure as ChapterTOCFailure {
      await preserve(
        bookID: book.id,
        existing: existing,
        failure: failure
      )
    } catch {
      await preserve(
        bookID: book.id,
        existing: existing,
        failure: .fetchFailed
      )
    }
  }

  private func preserve(
    bookID: LibraryDomain.BookID,
    existing: [LibraryDomain.BookChapter],
    failure: ChapterTOCFailure
  ) async {
    let update = ChapterTOCUpdatePolicy.shelfUpdate(
      existing: existing,
      fetched: nil,
      failure: failure
    )
    chapters =
      (try? await repository.applyTOCUpdate(
        bookID: bookID,
        update: update
      )) ?? existing
    state = .failed
    errorMessage = failure == .missingSource
      ? "找不到对应书源，已保留原目录"
      : "目录加载失败，已保留原目录"
  }
}
