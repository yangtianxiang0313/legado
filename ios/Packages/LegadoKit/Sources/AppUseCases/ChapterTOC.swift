import Foundation
import LibraryDomain
import Observation
import RuleRuntime
import SourceRuntime

public protocol BookChapterLoading: Sendable {
  func load(
    book: ShelfBookItem
  ) async throws -> BookChapterLoadResult
}

public struct BookChapterLoadResult: Equatable, Sendable {
  public let chapters: [LibraryDomain.BookChapter]
  public let bookVariables: [String: String]
  public let tocURL: String?

  public init(
    chapters: [LibraryDomain.BookChapter],
    bookVariables: [String: String],
    tocURL: String? = nil
  ) {
    self.chapters = chapters
    self.bookVariables = bookVariables
    self.tocURL = tocURL
  }
}

public enum ReaderTOCOrderPolicy {
  public struct Projection: Equatable, Sendable {
    public let chapters: [LibraryDomain.BookChapter]
    public let progress: ReadingProgress

    public init(
      chapters: [LibraryDomain.BookChapter],
      progress: ReadingProgress
    ) {
      self.chapters = chapters
      self.progress = progress
    }
  }

  public static func ordered(
    _ chapters: [LibraryDomain.BookChapter],
    reversed: Bool
  ) -> [LibraryDomain.BookChapter] {
    let sourceOrder = chapters.sorted {
      if $0.index == $1.index { return $0.id.rawValue < $1.id.rawValue }
      return $0.index < $1.index
    }
    let ordered = reversed ? Array(sourceOrder.reversed()) : sourceOrder
    return ordered.enumerated().map { index, chapter in
      LibraryDomain.BookChapter(
        id: chapter.id,
        bookID: chapter.bookID,
        sourceID: chapter.sourceID,
        index: index,
        title: chapter.title,
        url: chapter.url,
        requestExpression: chapter.requestExpression,
        isPay: chapter.isPay,
        isVIP: chapter.isVIP,
        isVolume: chapter.isVolume,
        variables: chapter.variables
      )
    }
  }

  public static func migrating(
    _ chapters: [LibraryDomain.BookChapter],
    progress: ReadingProgress,
    reversed: Bool
  ) -> Projection {
    let sourceOrder = ordered(chapters, reversed: false)
    let current = sourceOrder.first(where: {
      $0.index == progress.position.chapterIndex
    }) ?? sourceOrder.first(where: { $0.title == progress.chapterTitle })
    let projected = ordered(sourceOrder, reversed: reversed)
    let remappedIndex = current.flatMap { current in
      projected.firstIndex(where: { $0.id == current.id })
    } ?? min(
      max(0, progress.position.chapterIndex),
      max(0, projected.count - 1)
    )
    return Projection(
      chapters: projected,
      progress: ReadingProgress(
        position: ReadingPosition(
          chapterIndex: remappedIndex,
          characterOffset: progress.position.characterOffset
        ),
        chapterTitle: current?.title ?? progress.chapterTitle,
        updatedAtMilliseconds: progress.updatedAtMilliseconds
      )
    )
  }
}

public struct SourceBookChapterLoader: BookChapterLoading, Sendable {
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
      scriptRuntime: scriptRuntime,
      htmlSelectorBackend: htmlSelectorBackend
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
      bookVariables: execution.book.variables,
      tocURL: execution.book.tocURL?.absoluteString
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
      let ordered = ReaderTOCOrderPolicy.ordered(
        fetched.chapters,
        reversed: book.reversesTableOfContents
      )
      let update = ChapterTOCUpdatePolicy.shelfUpdate(
        existing: existing,
        fetched: ordered
      )
      chapters = try await repository.applyTOCUpdate(
        bookID: book.id,
        update: update,
        bookVariables: fetched.bookVariables,
        tocURL: fetched.tocURL
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
