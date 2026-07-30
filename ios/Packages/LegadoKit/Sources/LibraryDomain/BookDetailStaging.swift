public struct BookReadingProgress: Equatable, Sendable {
  public let chapterIndex: Int
  public let chapterPosition: Int

  public init(chapterIndex: Int, chapterPosition: Int) {
    self.chapterIndex = chapterIndex
    self.chapterPosition = chapterPosition
  }
}

public enum ShelfMembership: Equatable, Sendable {
  case staged
  case member(groupID: Int)

  public var isInBookshelf: Bool {
    if case .member = self {
      return true
    }
    return false
  }

  public var groupID: Int {
    switch self {
    case .staged:
      return 0
    case .member(let groupID):
      return groupID
    }
  }
}

public struct LibraryBook: Equatable, Sendable {
  public let id: BookID
  public let title: String
  public let author: String
  public var progress: BookReadingProgress?
  public var order: Int64
  public var membership: ShelfMembership

  public init(
    id: BookID,
    title: String,
    author: String,
    progress: BookReadingProgress? = nil,
    order: Int64 = 0,
    membership: ShelfMembership = .staged
  ) {
    self.id = id
    self.title = title
    self.author = author
    self.progress = progress
    self.order = order
    self.membership = membership
  }
}

public struct BookDetailStagingObservation: Equatable, Sendable {
  public let bookPersisted: Bool
  public let chapterCount: Int
  public let copiedProgress: Bool
  public let groupID: Int
  public let inBookshelf: Bool
  public let orderBeforePreviousMinimum: Bool
}

/// Platform-independent lifecycle used between a search result and a durable shelf entry.
///
/// Persisted book existence and shelf membership are deliberately separate. Android persists
/// temporary detail/TOC state before the user adds the book, so `groupID == 0` cannot be used as
/// a proxy for either persistence or membership.
public struct BookDetailStagingState: Equatable, Sendable {
  public private(set) var storedBook: LibraryBook?
  public private(set) var chapterCount: Int

  private let priorBook: LibraryBook?
  private let previousMinimumOrder: Int64?
  private var copiedProgress: Bool

  public init(
    priorBook: LibraryBook? = nil,
    previousMinimumOrder: Int64? = nil
  ) {
    self.storedBook = priorBook
    self.chapterCount = 0
    self.priorBook = priorBook
    self.previousMinimumOrder = previousMinimumOrder
    self.copiedProgress = false
  }

  public mutating func saveCandidate(_ candidate: LibraryBook) {
    var staged = candidate
    staged.membership = .staged
    copiedProgress = false
    if let priorBook, priorBook.id == candidate.id, let progress = priorBook.progress {
      staged.progress = progress
      copiedProgress = true
    }
    if let previousMinimumOrder {
      staged.order = previousMinimumOrder - 1
    }
    storedBook = staged
  }

  public mutating func explicitlyAdd(
    _ candidate: LibraryBook,
    chapterCount: Int
  ) {
    persist(candidate, membership: .member(groupID: 0), chapterCount: chapterCount)
  }

  public mutating func stageTableOfContents(
    _ candidate: LibraryBook,
    chapterCount: Int
  ) {
    persist(candidate, membership: .staged, chapterCount: chapterCount)
  }

  public mutating func selectGroup(
    _ groupID: Int,
    candidate: LibraryBook,
    chapterCount: Int
  ) {
    guard groupID > 0 else { return }
    persist(
      candidate,
      membership: .member(groupID: groupID),
      chapterCount: chapterCount
    )
  }

  public mutating func discardFromReaderIfStaged() {
    guard storedBook?.membership == .staged else { return }
    storedBook = nil
    chapterCount = 0
    copiedProgress = false
  }

  public var observation: BookDetailStagingObservation {
    let membership = storedBook?.membership ?? .staged
    return BookDetailStagingObservation(
      bookPersisted: storedBook != nil,
      chapterCount: chapterCount,
      copiedProgress: copiedProgress,
      groupID: membership.groupID,
      inBookshelf: membership.isInBookshelf,
      orderBeforePreviousMinimum: {
        guard
          let order = storedBook?.order,
          let previousMinimumOrder
        else {
          return false
        }
        return order < previousMinimumOrder
      }()
    )
  }

  private mutating func persist(
    _ candidate: LibraryBook,
    membership: ShelfMembership,
    chapterCount: Int
  ) {
    var stored = candidate
    stored.membership = membership
    storedBook = stored
    self.chapterCount = max(0, chapterCount)
    copiedProgress = false
  }
}
