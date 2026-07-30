import LibraryDomain
import Observation
import ReaderCore
import SourceRuntime

public protocol ReaderContentLoading: Sendable {
  func load(
    book: ShelfBookItem,
    chapter: LibraryDomain.BookChapter,
    characterOffset: Int
  ) async throws -> ReaderDocument
}

public protocol ChapterBoundaryReaderContentLoading:
  ReaderContentLoading
{
  func load(
    book: ShelfBookItem,
    chapter: LibraryDomain.BookChapter,
    nextChapter: LibraryDomain.BookChapter?,
    characterOffset: Int
  ) async throws -> ReaderDocument
}

public struct SourceReaderContentResult: Equatable, Sendable {
  public let document: ReaderDocument
  public let chapterVariables: [String: String]

  public init(
    document: ReaderDocument,
    chapterVariables: [String: String]
  ) {
    self.document = document
    self.chapterVariables = chapterVariables
  }
}

public protocol SourceVariableReaderContentLoading:
  ChapterBoundaryReaderContentLoading
{
  func loadSourceContent(
    book: ShelfBookItem,
    chapter: LibraryDomain.BookChapter,
    nextChapter: LibraryDomain.BookChapter?,
    characterOffset: Int
  ) async throws -> SourceReaderContentResult
}

public struct SourceReaderContentLoader:
  SourceVariableReaderContentLoading, Sendable
{
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
    book: ShelfBookItem,
    chapter: LibraryDomain.BookChapter,
    characterOffset: Int
  ) async throws -> ReaderDocument {
    try await load(
      book: book,
      chapter: chapter,
      nextChapter: nil,
      characterOffset: characterOffset
    )
  }

  public func load(
    book: ShelfBookItem,
    chapter: LibraryDomain.BookChapter,
    nextChapter: LibraryDomain.BookChapter?,
    characterOffset: Int
  ) async throws -> ReaderDocument {
    try await loadSourceContent(
      book: book,
      chapter: chapter,
      nextChapter: nextChapter,
      characterOffset: characterOffset
    ).document
  }

  public func loadSourceContent(
    book: ShelfBookItem,
    chapter: LibraryDomain.BookChapter,
    nextChapter: LibraryDomain.BookChapter?,
    characterOffset: Int
  ) async throws -> SourceReaderContentResult {
    guard
      let source = sources.first(where: {
        $0.id == chapter.sourceID
          || $0.definition.sourceURL == chapter.sourceID
      })
    else {
      throw ChapterTOCFailure.missingSource
    }
    let execution = try await SourceContentPipeline(
      definition: source.definition,
      transport: transport,
      cookieStore: cookieStore,
      dynamicWebPagePort: dynamicWebPagePort,
      scriptRuntime: scriptRuntime
    ).content(
      chapterURL: chapter.requestExpression,
      nextChapterURL: nextChapter?.requestExpression,
      bookVariables: book.candidate.variables,
      chapterVariables: chapter.variables
    )
    let document = ReaderDocument(
      position: ReaderPosition(
        bookID: book.id,
        chapterID: chapter.id,
        chapterIndex: chapter.index,
        characterOffset: characterOffset
      ),
      title: chapter.title,
      content: execution.content.content
    )
    return SourceReaderContentResult(
      document: document,
      chapterVariables: execution.content.variables
    )
  }
}

public struct RepositoryReaderContentLoader:
  ReaderContentLoading, Sendable
{
  private let repository: any BookShelfRepository
  private let fallback: any ReaderContentLoading

  public init(
    repository: any BookShelfRepository,
    fallback: any ReaderContentLoading
  ) {
    self.repository = repository
    self.fallback = fallback
  }

  public func load(
    book: ShelfBookItem,
    chapter: LibraryDomain.BookChapter,
    characterOffset: Int
  ) async throws -> ReaderDocument {
    if
      let content = try await repository.chapterContent(
        bookID: book.id,
        chapterID: chapter.id
      )
    {
      return ReaderDocument(
        position: ReaderPosition(
          bookID: book.id,
          chapterID: chapter.id,
          chapterIndex: chapter.index,
          characterOffset: max(0, characterOffset)
        ),
        title: chapter.title,
        content: content
      )
    }
    let chapters = try await repository.chapters(
      bookID: book.id
    ).sorted { $0.index < $1.index }
    let index = chapters.firstIndex { $0.id == chapter.id }
    let nextChapter = index.flatMap {
      chapters.indices.contains($0 + 1)
        ? chapters[$0 + 1]
        : chapters.first
    }
    let document: ReaderDocument
    if
      let sourceLoader =
        fallback as? any SourceVariableReaderContentLoading
    {
      let result = try await sourceLoader.loadSourceContent(
        book: book,
        chapter: chapter,
        nextChapter: nextChapter,
        characterOffset: characterOffset
      )
      try await repository.saveSourceVariables(
        bookID: book.id,
        bookVariables: nil,
        chapterID: chapter.id,
        chapterVariables: result.chapterVariables
      )
      document = result.document
    } else if
      let boundaryLoader =
        fallback as? any ChapterBoundaryReaderContentLoading
    {
      document = try await boundaryLoader.load(
        book: book,
        chapter: chapter,
        nextChapter: nextChapter,
        characterOffset: characterOffset
      )
    } else {
      document = try await fallback.load(
        book: book,
        chapter: chapter,
        characterOffset: characterOffset
      )
    }
    if !document.content.isEmpty {
      try await repository.saveChapterContent(
        document.content,
        bookID: book.id,
        chapterID: chapter.id
      )
    }
    return document
  }
}

public struct ReplacementNormalizingReaderContentLoader:
  ReaderContentLoading, Sendable
{
  private let base: any ReaderContentLoading
  private let rules: any ReaderReplacementRuleRepository

  public init(
    base: any ReaderContentLoading,
    rules: any ReaderReplacementRuleRepository
  ) {
    self.base = base
    self.rules = rules
  }

  public func load(
    book: ShelfBookItem,
    chapter: LibraryDomain.BookChapter,
    characterOffset: Int
  ) async throws -> ReaderDocument {
    let raw = try await base.load(
      book: book,
      chapter: chapter,
      characterOffset: characterOffset
    )
    let storedRules = (try? await rules.replacementRules()) ?? []
    let normalized = AndroidReaderContentNormalizationPolicy.normalize(
      ReaderContentNormalizationInput(
        bookName: book.candidate.name,
        bookOrigin: book.candidate.sourceID,
        chapterTitle: raw.title,
        content: raw.content,
        includeTitle: false,
        useReplacementRules: true,
        paragraphIndent: "　　",
        rules: storedRules.map(\.contentRule)
      )
    )
    return ReaderDocument(
      position: raw.position,
      title: normalized.displayTitle,
      content: normalized.renderedText
    )
  }
}

public enum ReaderContentLoadingState: Equatable, Sendable {
  case idle
  case loading
  case loaded
  case failed
}

@MainActor
@Observable
public final class ReaderContentSession {
  public private(set) var document: ReaderDocument?
  public private(set) var state: ReaderContentLoadingState = .idle
  public private(set) var errorMessage: String?

  private let loader: any ReaderContentLoading

  public init(loader: any ReaderContentLoading) {
    self.loader = loader
  }

  public func load(
    book: ShelfBookItem,
    chapter: LibraryDomain.BookChapter,
    characterOffset: Int
  ) async {
    state = .loading
    document = nil
    do {
      document = try await loader.load(
        book: book,
        chapter: chapter,
        characterOffset: max(0, characterOffset)
      )
      state = .loaded
      errorMessage = nil
    } catch {
      state = .failed
      errorMessage = "正文加载失败"
    }
  }
}
