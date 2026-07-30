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
    guard state != .loading else { return }
    state = .loading
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
