import Foundation
import LibraryDomain
import Observation
import SourceRuntime

public protocol BookChapterLoading: Sendable {
  func load(
    book: ShelfBookItem
  ) async throws -> [LibraryDomain.BookChapter]
}

public struct SourceBookChapterLoader: BookChapterLoading, Sendable {
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
    book: ShelfBookItem
  ) async throws -> [LibraryDomain.BookChapter] {
    let candidate = book.candidate
    guard
      let source = sources.first(where: {
        $0.id == candidate.sourceID
          || $0.definition.sourceURL == candidate.sourceID
      })
    else {
      throw ChapterTOCFailure.missingSource
    }
    let execution = try await SourceTOCPipeline(
      definition: source.definition,
      transport: transport
    ).chapters(bookURL: candidate.bookURL)
    return execution.chapters.map {
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
        isPay: $0.isPay,
        isVIP: $0.isVIP,
        isVolume: $0.isVolume
      )
    }
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
        fetched: fetched
      )
      chapters = try await repository.applyTOCUpdate(
        bookID: book.id,
        update: update
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
