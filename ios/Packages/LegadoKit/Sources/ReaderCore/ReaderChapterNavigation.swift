public struct ReaderChapterWindow: Equatable, Sendable {
  public let chapterIndex: Int
  public let pageStarts: [Int]

  public init(chapterIndex: Int, pageStarts: [Int]) {
    self.chapterIndex = chapterIndex
    self.pageStarts = pageStarts
  }

  public var lastPageStart: Int? {
    pageStarts.last
  }

  func pageIndex(containing position: Int) -> Int? {
    guard !pageStarts.isEmpty, position >= pageStarts[0] else {
      return nil
    }
    var lower = 0
    var upper = pageStarts.count
    while lower < upper {
      let middle = lower + (upper - lower) / 2
      if pageStarts[middle] <= position {
        lower = middle + 1
      } else {
        upper = middle
      }
    }
    return lower - 1
  }
}

public struct ReaderChapterNavigationState: Equatable, Sendable {
  public let chapterCount: Int
  public var runtimeChapterIndex: Int
  public var runtimeChapterPosition: Int
  public var storedChapterIndex: Int
  public var storedChapterPosition: Int
  public var previous: ReaderChapterWindow?
  public var current: ReaderChapterWindow?
  public var next: ReaderChapterWindow?

  public init(
    chapterCount: Int,
    runtimeChapterIndex: Int,
    runtimeChapterPosition: Int,
    storedChapterIndex: Int,
    storedChapterPosition: Int,
    previous: ReaderChapterWindow?,
    current: ReaderChapterWindow?,
    next: ReaderChapterWindow?
  ) {
    self.chapterCount = chapterCount
    self.runtimeChapterIndex = runtimeChapterIndex
    self.runtimeChapterPosition = runtimeChapterPosition
    self.storedChapterIndex = storedChapterIndex
    self.storedChapterPosition = storedChapterPosition
    self.previous = previous
    self.current = current
    self.next = next
  }
}

public enum ReaderChapterNavigationAction: Equatable, Sendable {
  case nextPage
  case previousPage
  case nextChapter
  case previousChapter(toLast: Bool)
}

public enum ReaderChapterNavigationEffect: Equatable, Sendable {
  case refreshContent(resetPageOffset: Bool)
  case refreshMenu
  case pageChanged
}

public struct ReaderChapterNavigationOutcome: Equatable, Sendable {
  public let moved: Bool
  public let state: ReaderChapterNavigationState
  public let effects: [ReaderChapterNavigationEffect]

  public init(
    moved: Bool,
    state: ReaderChapterNavigationState,
    effects: [ReaderChapterNavigationEffect]
  ) {
    self.moved = moved
    self.state = state
    self.effects = effects
  }
}

public enum AndroidReaderChapterNavigation {
  public static func apply(
    _ action: ReaderChapterNavigationAction,
    to original: ReaderChapterNavigationState
  ) -> ReaderChapterNavigationOutcome {
    switch action {
    case .nextPage:
      return movePage(direction: 1, state: original)
    case .previousPage:
      return movePage(direction: -1, state: original)
    case .nextChapter:
      return moveToNextChapter(state: original)
    case .previousChapter(let toLast):
      return moveToPreviousChapter(state: original, toLast: toLast)
    }
  }

  private static func movePage(
    direction: Int,
    state original: ReaderChapterNavigationState
  ) -> ReaderChapterNavigationOutcome {
    guard
      let current = original.current,
      let pageIndex = current.pageIndex(
        containing: original.runtimeChapterPosition
      ),
      current.pageStarts.indices.contains(pageIndex + direction)
    else {
      return denied(original)
    }
    var state = original
    state.runtimeChapterPosition = current.pageStarts[pageIndex + direction]
    persistRuntimePosition(in: &state)
    return ReaderChapterNavigationOutcome(
      moved: true,
      state: state,
      effects: [.refreshContent(resetPageOffset: true)]
    )
  }

  private static func moveToNextChapter(
    state original: ReaderChapterNavigationState
  ) -> ReaderChapterNavigationOutcome {
    guard original.runtimeChapterIndex < original.chapterCount - 1 else {
      return denied(original)
    }
    var state = original
    state.runtimeChapterIndex += 1
    state.runtimeChapterPosition = 0
    state.previous = original.current
    state.current = original.next
    state.next = nil
    persistRuntimePosition(in: &state)
    return movedChapter(state)
  }

  private static func moveToPreviousChapter(
    state original: ReaderChapterNavigationState,
    toLast: Bool
  ) -> ReaderChapterNavigationOutcome {
    guard original.runtimeChapterIndex > 0 else {
      return denied(original)
    }
    var state = original
    state.runtimeChapterIndex -= 1
    state.runtimeChapterPosition =
      toLast
      ? original.previous?.lastPageStart ?? Int(Int32.max)
      : 0
    state.next = original.current
    state.current = original.previous
    state.previous = nil
    persistRuntimePosition(in: &state)
    return movedChapter(state)
  }

  private static func persistRuntimePosition(
    in state: inout ReaderChapterNavigationState
  ) {
    state.storedChapterIndex = state.runtimeChapterIndex
    state.storedChapterPosition = state.runtimeChapterPosition
  }

  private static func movedChapter(
    _ state: ReaderChapterNavigationState
  ) -> ReaderChapterNavigationOutcome {
    ReaderChapterNavigationOutcome(
      moved: true,
      state: state,
      effects: [
        .refreshContent(resetPageOffset: true),
        .refreshMenu,
        .pageChanged,
      ]
    )
  }

  private static func denied(
    _ state: ReaderChapterNavigationState
  ) -> ReaderChapterNavigationOutcome {
    ReaderChapterNavigationOutcome(
      moved: false,
      state: state,
      effects: []
    )
  }
}
