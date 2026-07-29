import LibraryDomain

public struct ReaderLayoutPage: Equatable, Hashable, Sendable {
  public let startCharacterOffset: Int
  public let characterCount: Int

  public init(startCharacterOffset: Int, characterCount: Int) {
    self.startCharacterOffset = startCharacterOffset
    self.characterCount = max(characterCount, 1)
  }
}

public enum ReaderLayoutMapError: Error, Equatable, Sendable {
  case pagesOutOfOrder
}

public struct ReaderLayoutMap: Equatable, Sendable {
  public let pages: [ReaderLayoutPage]
  public let isComplete: Bool

  public init(
    pages: [ReaderLayoutPage],
    isComplete: Bool
  ) throws {
    guard
      zip(pages, pages.dropFirst()).allSatisfy({
        $0.startCharacterOffset < $1.startCharacterOffset
      })
    else {
      throw ReaderLayoutMapError.pagesOutOfOrder
    }
    self.pages = pages
    self.isComplete = isComplete
  }

  public func characterOffset(forPageIndex pageIndex: Int) -> Int? {
    guard !pages.isEmpty else { return nil }
    guard pageIndex >= 0 else { return 0 }
    return pages[min(pageIndex, pages.count - 1)].startCharacterOffset
  }

  public func pageIndex(forCharacterOffset characterOffset: Int) -> Int? {
    guard
      !pages.isEmpty,
      characterOffset >= pages[0].startCharacterOffset
    else {
      return nil
    }
    var lower = 0
    var upper = pages.count
    while lower < upper {
      let middle = lower + (upper - lower) / 2
      if pages[middle].startCharacterOffset <= characterOffset {
        lower = middle + 1
      } else {
        upper = middle
      }
    }
    let index = lower - 1
    if !isComplete, index == pages.count - 1 {
      let page = pages[index]
      let pageEnd = page.startCharacterOffset + page.characterCount
      if characterOffset > pageEnd {
        return nil
      }
    }
    return index
  }
}

public struct ReaderProgressSnapshot: Equatable, Sendable {
  public let progress: ReadingProgress
  public let contentCheckCount: Int

  public init(
    progress: ReadingProgress,
    contentCheckCount: Int
  ) {
    self.progress = progress
    self.contentCheckCount = contentCheckCount
  }
}

public enum ReaderProgressSaveEvent: Equatable, Sendable {
  case pageChanged
  case lifecycle
  case audio
}

public enum AndroidReaderProgressCompatibility {
  public static func position(
    afterSelectingPage pageIndex: Int,
    current: ReadingPosition,
    layout: ReaderLayoutMap
  ) -> ReadingPosition? {
    guard
      let characterOffset = layout.characterOffset(
        forPageIndex: pageIndex
      )
    else {
      return nil
    }
    return ReadingPosition(
      chapterIndex: current.chapterIndex,
      characterOffset: characterOffset
    )
  }

  public static func resetPosition(
    stored: ReadingPosition,
    chapterCount: Int
  ) -> ReadingPosition {
    let lastIndex = max(chapterCount - 1, 0)
    return ReadingPosition(
      chapterIndex: min(max(stored.chapterIndex, 0), lastIndex),
      characterOffset: stored.characterOffset
    )
  }

  public static func shouldResolveChapterTitle(
    stored: ReaderProgressSnapshot,
    runtimePosition: ReadingPosition,
    event: ReaderProgressSaveEvent
  ) -> Bool {
    event != .pageChanged
      || stored.progress.position.chapterIndex
        != runtimePosition.chapterIndex
  }

  public static func saving(
    stored: ReaderProgressSnapshot,
    runtimePosition: ReadingPosition,
    event: ReaderProgressSaveEvent,
    nowMilliseconds: Int64,
    resolvedChapterTitle: String?
  ) -> ReaderProgressSnapshot {
    let shouldResolve = shouldResolveChapterTitle(
      stored: stored,
      runtimePosition: runtimePosition,
      event: event
    )
    return ReaderProgressSnapshot(
      progress: ReadingProgress(
        position: runtimePosition,
        chapterTitle:
          shouldResolve
          ? resolvedChapterTitle ?? stored.progress.chapterTitle
          : stored.progress.chapterTitle,
        updatedAtMilliseconds: nowMilliseconds
      ),
      contentCheckCount: 0
    )
  }
}

public protocol ReaderProgressStore: Sendable {
  func snapshot(for bookID: String) async throws
    -> ReaderProgressSnapshot
  func save(
    _ snapshot: ReaderProgressSnapshot,
    for bookID: String
  ) async throws
}

public protocol ChapterTitleResolver: Sendable {
  func title(for bookID: String, chapterIndex: Int) async throws
    -> String?
}

public protocol ReaderProgressClock: Sendable {
  func nowMilliseconds() -> Int64
}

public struct ReaderProgressCoordinator: Sendable {
  private let store: any ReaderProgressStore
  private let titleResolver: any ChapterTitleResolver
  private let clock: any ReaderProgressClock

  public init(
    store: any ReaderProgressStore,
    titleResolver: any ChapterTitleResolver,
    clock: any ReaderProgressClock
  ) {
    self.store = store
    self.titleResolver = titleResolver
    self.clock = clock
  }

  @discardableResult
  public func save(
    bookID: String,
    runtimePosition: ReadingPosition,
    event: ReaderProgressSaveEvent
  ) async throws -> ReaderProgressSnapshot {
    let stored = try await store.snapshot(for: bookID)
    let title: String?
    if AndroidReaderProgressCompatibility.shouldResolveChapterTitle(
      stored: stored,
      runtimePosition: runtimePosition,
      event: event
    ) {
      title = try await titleResolver.title(
        for: bookID,
        chapterIndex: runtimePosition.chapterIndex
      )
    } else {
      title = nil
    }
    let updated = AndroidReaderProgressCompatibility.saving(
      stored: stored,
      runtimePosition: runtimePosition,
      event: event,
      nowMilliseconds: clock.nowMilliseconds(),
      resolvedChapterTitle: title
    )
    try await store.save(updated, for: bookID)
    return updated
  }
}
