import LibraryDomain

public struct ReaderTOCRefreshRequest: Equatable, Sendable {
  public let bookID: BookID
  public let requestedAtMilliseconds: Int64

  public init(
    bookID: BookID,
    requestedAtMilliseconds: Int64
  ) {
    self.bookID = bookID
    self.requestedAtMilliseconds = requestedAtMilliseconds
  }
}

public enum ReaderTOCRefreshSkipReason: Equatable, Sendable {
  case missingSource
  case missingBook
  case updateDisabled
  case throttled
}

public struct ReaderTOCRefreshStart: Equatable, Sendable {
  public let request: ReaderTOCRefreshRequest?
  public let lastCheckMilliseconds: Int64
  public let skipReason: ReaderTOCRefreshSkipReason?

  public init(
    request: ReaderTOCRefreshRequest?,
    lastCheckMilliseconds: Int64,
    skipReason: ReaderTOCRefreshSkipReason?
  ) {
    self.request = request
    self.lastCheckMilliseconds = lastCheckMilliseconds
    self.skipReason = skipReason
  }
}

public enum ReaderTOCRefreshEffect: Equatable, Sendable {
  case replaceChapters([BookChapter])
  case updateChapterCount(Int)
  case loadChapter(index: Int)
}

public struct ReaderTOCRefreshOutcome: Equatable, Sendable {
  public let acceptedChapters: [BookChapter]?
  public let effects: [ReaderTOCRefreshEffect]

  public init(
    acceptedChapters: [BookChapter]?,
    effects: [ReaderTOCRefreshEffect]
  ) {
    self.acceptedChapters = acceptedChapters
    self.effects = effects
  }
}

public enum AndroidReaderTOCRefreshRuntime {
  public static let throttleMilliseconds: Int64 = 10 * 60 * 1_000

  public static func begin(
    bookID: BookID?,
    hasSource: Bool,
    canUpdate: Bool,
    nowMilliseconds: Int64,
    lastCheckMilliseconds: Int64
  ) -> ReaderTOCRefreshStart {
    guard hasSource else {
      return skipped(.missingSource, lastCheckMilliseconds)
    }
    guard let bookID else {
      return skipped(.missingBook, lastCheckMilliseconds)
    }
    guard canUpdate else {
      return skipped(.updateDisabled, lastCheckMilliseconds)
    }
    guard
      nowMilliseconds - lastCheckMilliseconds >= throttleMilliseconds
    else {
      return skipped(.throttled, lastCheckMilliseconds)
    }
    return ReaderTOCRefreshStart(
      request: ReaderTOCRefreshRequest(
        bookID: bookID,
        requestedAtMilliseconds: nowMilliseconds
      ),
      lastCheckMilliseconds: nowMilliseconds,
      skipReason: nil
    )
  }

  public static func finish(
    request: ReaderTOCRefreshRequest,
    activeBookID: BookID?,
    fetched: [BookChapter],
    currentChapterCount: Int,
    currentChapterIndex: Int,
    nextChapterIsLoaded: Bool
  ) -> ReaderTOCRefreshOutcome {
    guard
      request.bookID == activeBookID,
      fetched.count > currentChapterCount
    else {
      return ReaderTOCRefreshOutcome(
        acceptedChapters: nil,
        effects: []
      )
    }
    var effects: [ReaderTOCRefreshEffect] = [
      .replaceChapters(fetched),
      .updateChapterCount(fetched.count),
    ]
    if !nextChapterIsLoaded {
      effects.append(.loadChapter(index: currentChapterIndex + 1))
    }
    return ReaderTOCRefreshOutcome(
      acceptedChapters: fetched,
      effects: effects
    )
  }

  private static func skipped(
    _ reason: ReaderTOCRefreshSkipReason,
    _ lastCheckMilliseconds: Int64
  ) -> ReaderTOCRefreshStart {
    ReaderTOCRefreshStart(
      request: nil,
      lastCheckMilliseconds: lastCheckMilliseconds,
      skipReason: reason
    )
  }
}
