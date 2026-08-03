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

public struct OfflineCacheRequest: Equatable, Sendable {
  public let bookID: LibraryDomain.BookID
  public let chapterIndexes: ClosedRange<Int>?

  public init(
    bookID: LibraryDomain.BookID,
    chapterIndexes: ClosedRange<Int>? = nil
  ) {
    self.bookID = bookID
    self.chapterIndexes = chapterIndexes
  }
}

public struct ReaderChapterPrefetchPlan: Equatable, Sendable {
  public let forward: [Int]
  public let backward: [Int]

  public init(
    currentChapterIndex: Int,
    chapterCount: Int,
    preDownloadCount: Int
  ) {
    guard chapterCount > 0, preDownloadCount >= 2 else {
      forward = []
      backward = []
      return
    }
    let lastIndex = chapterCount - 1
    let forwardStart = currentChapterIndex + 2
    let forwardEnd = min(currentChapterIndex + preDownloadCount, lastIndex)
    forward = forwardStart <= forwardEnd
      ? Array(forwardStart...forwardEnd)
      : []

    let backwardStart = currentChapterIndex - 2
    let backwardEnd = max(
      0,
      currentChapterIndex - min(5, preDownloadCount)
    )
    backward = backwardStart >= backwardEnd
      ? Array(stride(from: backwardStart, through: backwardEnd, by: -1))
      : []
  }

  public var isEmpty: Bool {
    forward.isEmpty && backward.isEmpty
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
    await cacheOffline(
      requests: bookIDs.map { OfflineCacheRequest(bookID: $0) },
      loader: loader
    )
  }

  @discardableResult
  func cacheOffline(
    bookID: LibraryDomain.BookID,
    chapterIndexes: ClosedRange<Int>,
    loader: any ReaderContentLoading
  ) async -> OfflineCacheReport {
    await cacheOffline(
      requests: [
        OfflineCacheRequest(
          bookID: bookID,
          chapterIndexes: chapterIndexes
        )
      ],
      loader: loader
    )
  }

  @discardableResult
  func cacheOffline(
    requests: [OfflineCacheRequest],
    loader: any ReaderContentLoading
  ) async -> OfflineCacheReport {
    await cacheOffline(
      requests: requests,
      loader: loader,
      tracksManualCacheProgress: true
    )
  }

  @discardableResult
  func prefetchReaderChapters(
    bookID: LibraryDomain.BookID,
    currentChapterIndex: Int,
    preDownloadCount: Int,
    loader: any ReaderContentLoading
  ) async -> OfflineCacheReport {
    let chapterCount = await chapters(bookID: bookID).count
    let plan = ReaderChapterPrefetchPlan(
      currentChapterIndex: currentChapterIndex,
      chapterCount: chapterCount,
      preDownloadCount: preDownloadCount
    )
    let requests: [OfflineCacheRequest] = [
      plan.forward, plan.backward,
    ].compactMap { indexes -> OfflineCacheRequest? in
      guard let lower = indexes.min(), let upper = indexes.max() else {
        return nil
      }
      return OfflineCacheRequest(
        bookID: bookID,
        chapterIndexes: lower...upper
      )
    }
    return await cacheOffline(
      requests: requests,
      loader: loader,
      tracksManualCacheProgress: false
    )
  }

  private func cacheOffline(
    requests: [OfflineCacheRequest],
    loader: any ReaderContentLoading,
    tracksManualCacheProgress: Bool
  ) async -> OfflineCacheReport {
    if tracksManualCacheProgress {
      offlineCacheState = .caching
      offlineCacheProgress = 0
    }
    let registry = SourceCacheQueueRegistry()
    var requestedCount = 0
    var cachedCount = 0
    var skippedCount = 0
    var failedCount = 0
    var cancelledCount = 0

    for request in requests {
      guard let book = try? await repository.book(id: request.bookID) else {
        continue
      }
      let allChapters =
        ((try? await repository.chapters(bookID: request.bookID)) ?? [])
        .sorted { $0.index < $1.index }
      let chapters = allChapters.filter { chapter in
        request.chapterIndexes?.contains(chapter.index) ?? true
      }
      requestedCount += chapters.count
      if AndroidWebDAVBookOrigin.isLocalSource(book.candidate.sourceID) {
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
          if tracksManualCacheProgress {
            offlineCacheProgress += 1
          }
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
              let chapterPosition = allChapters.firstIndex {
                $0.id == chapter.id
              }
              let nextChapter = chapterPosition.flatMap { position in
                allChapters.indices.contains(position + 1)
                  ? allChapters[position + 1]
                  : allChapters.first
              }
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
            if Task.isCancelled {
              await queue.stop()
              cancelledCount += 1
              finished = true
              continue
            }
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
        if tracksManualCacheProgress {
          offlineCacheProgress += 1
        }
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
    if tracksManualCacheProgress {
      lastOfflineCacheReport = report
      offlineCacheState =
        failedCount > 0 ? .failed : .completed
    }
    return report
  }
}
