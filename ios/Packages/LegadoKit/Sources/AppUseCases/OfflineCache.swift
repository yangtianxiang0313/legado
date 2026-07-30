import LibraryDomain
import ReaderCore
import SourceRuntime

public enum OfflineCacheState: Equatable, Sendable {
  case idle
  case caching
  case completed
  case failed
}

public struct OfflineCacheReport: Equatable, Sendable {
  public let requestedCount: Int
  public let cachedCount: Int
  public let skippedCount: Int
  public let failedCount: Int
  public let cancelledCount: Int

  public init(
    requestedCount: Int,
    cachedCount: Int,
    skippedCount: Int,
    failedCount: Int,
    cancelledCount: Int
  ) {
    self.requestedCount = requestedCount
    self.cachedCount = cachedCount
    self.skippedCount = skippedCount
    self.failedCount = failedCount
    self.cancelledCount = cancelledCount
  }
}

private enum OfflineCacheFailure: Error {
  case emptyContent
}

@MainActor
public extension ShelfLibrary {
  @discardableResult
  func cacheOffline(
    bookIDs: [LibraryDomain.BookID],
    loader: any ReaderContentLoading
  ) async -> OfflineCacheReport {
    offlineCacheState = .caching
    offlineCacheProgress = 0
    let registry = SourceCacheQueueRegistry()
    var requestedCount = 0
    var cachedCount = 0
    var skippedCount = 0
    var failedCount = 0
    var cancelledCount = 0

    for bookID in bookIDs {
      guard let book = try? await repository.book(id: bookID) else {
        continue
      }
      let chapters =
        ((try? await repository.chapters(bookID: bookID)) ?? [])
        .sorted { $0.index < $1.index }
      requestedCount += chapters.count
      if book.candidate.sourceID == "local-file" {
        skippedCount += chapters.count
        continue
      }

      let queue = await registry.model(
        for: book.candidate.bookURL
      )
      for chapter in chapters {
        await queue.addDownload(chapter.index...chapter.index)
      }
      for (offset, chapter) in chapters.enumerated() {
        if Task.isCancelled {
          await queue.stop()
          cancelledCount += chapters.count - offset
          break
        }
        if
          let existing = try? await repository.chapterContent(
            bookID: book.id,
            chapterID: chapter.id
          ),
          !existing.isEmpty
        {
          skippedCount += 1
          await queue.completeSuccess(
            index: chapter.index,
            key: chapter.id.rawValue
          )
          offlineCacheProgress += 1
          continue
        }

        var finished = false
        while !finished {
          await queue.beginAttempt(chapter.index)
          do {
            let document: ReaderDocument
            if
              let boundaryLoader =
                loader as? any ChapterBoundaryReaderContentLoading
            {
              let nextChapter =
                chapters.indices.contains(offset + 1)
                ? chapters[offset + 1]
                : chapters.first
              document = try await boundaryLoader.load(
                book: book,
                chapter: chapter,
                nextChapter: nextChapter,
                characterOffset: 0
              )
            } else {
              document = try await loader.load(
                book: book,
                chapter: chapter,
                characterOffset: 0
              )
            }
            guard !document.content.isEmpty else {
              throw OfflineCacheFailure.emptyContent
            }
            try await repository.saveChapterContent(
              document.content,
              bookID: book.id,
              chapterID: chapter.id
            )
            await queue.completeSuccess(
              index: chapter.index,
              key: chapter.id.rawValue
            )
            cachedCount += 1
            finished = true
          } catch {
            let transition = await queue.recordFailure(
              index: chapter.index,
              key: chapter.id.rawValue,
              kind: .ordinary
            )
            if !transition.requeued {
              failedCount += 1
              finished = true
            }
          }
        }
        offlineCacheProgress += 1
      }
      await registry.finish(book.candidate.bookURL)
    }

    let report = OfflineCacheReport(
      requestedCount: requestedCount,
      cachedCount: cachedCount,
      skippedCount: skippedCount,
      failedCount: failedCount,
      cancelledCount: cancelledCount
    )
    lastOfflineCacheReport = report
    offlineCacheState =
      failedCount > 0 ? .failed : .completed
    return report
  }
}
