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

public struct SourceReaderContentLoader: ReaderContentLoading, Sendable {
  private let sources: [SearchSourceDescriptor]
  private let transport: any HTTPTransport

  public init(
    sources: [SearchSourceDescriptor],
    transport: any HTTPTransport
  ) {
    self.sources = sources
    self.transport = transport
  }

  public func load(
    book: ShelfBookItem,
    chapter: LibraryDomain.BookChapter,
    characterOffset: Int
  ) async throws -> ReaderDocument {
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
      transport: transport
    ).content(chapterURL: chapter.url)
    return ReaderDocument(
      position: ReaderPosition(
        bookID: book.id,
        chapterID: chapter.id,
        chapterIndex: chapter.index,
        characterOffset: characterOffset
      ),
      title: chapter.title,
      content: execution.content.content
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
    return try await fallback.load(
      book: book,
      chapter: chapter,
      characterOffset: characterOffset
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
