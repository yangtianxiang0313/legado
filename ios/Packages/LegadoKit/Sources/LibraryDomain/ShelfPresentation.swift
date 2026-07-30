import Foundation

public enum ShelfSortMode: Int, CaseIterable, Sendable {
  case recentlyRead = 0
  case recentlyUpdated = 1
  case name = 2
  case manual = 3
  case combinedTime = 4
}

public struct ShelfGroupSortPreference: Equatable, Sendable {
  public let override: ShelfSortMode?

  public init(override: ShelfSortMode?) {
    self.override = override
  }

  public func resolved(global: ShelfSortMode) -> ShelfSortMode {
    override ?? global
  }
}

public struct ShelfPresentationBook: Equatable, Sendable {
  public let id: BookID
  public let name: String
  public let manualOrder: Int64
  public let latestChapterTime: Int64
  public let lastReadTime: Int64

  public init(
    id: BookID,
    name: String,
    manualOrder: Int64,
    latestChapterTime: Int64,
    lastReadTime: Int64
  ) {
    self.id = id
    self.name = name
    self.manualOrder = manualOrder
    self.latestChapterTime = latestChapterTime
    self.lastReadTime = lastReadTime
  }
}

public enum ShelfBookOrdering {
  public static func sort(
    _ books: [ShelfPresentationBook],
    by mode: ShelfSortMode
  ) -> [ShelfPresentationBook] {
    books.enumerated().sorted { lhs, rhs in
      let order = compare(lhs.element, rhs.element, mode: mode)
      return order == .orderedSame
        ? lhs.offset < rhs.offset
        : order == .orderedAscending
    }.map(\.element)
  }

  private static func compare(
    _ lhs: ShelfPresentationBook,
    _ rhs: ShelfPresentationBook,
    mode: ShelfSortMode
  ) -> ComparisonResult {
    switch mode {
    case .recentlyRead:
      descending(lhs.lastReadTime, rhs.lastReadTime)
    case .recentlyUpdated:
      descending(lhs.latestChapterTime, rhs.latestChapterTime)
    case .name:
      lhs.name.compare(
        rhs.name,
        options: [],
        range: nil,
        locale: Locale(identifier: "zh-Hans-CN")
      )
    case .manual:
      ascending(lhs.manualOrder, rhs.manualOrder)
    case .combinedTime:
      descending(
        max(lhs.latestChapterTime, lhs.lastReadTime),
        max(rhs.latestChapterTime, rhs.lastReadTime)
      )
    }
  }

  private static func ascending<T: Comparable>(
    _ lhs: T,
    _ rhs: T
  ) -> ComparisonResult {
    lhs == rhs ? .orderedSame : lhs < rhs ? .orderedAscending : .orderedDescending
  }

  private static func descending<T: Comparable>(
    _ lhs: T,
    _ rhs: T
  ) -> ComparisonResult {
    lhs == rhs ? .orderedSame : lhs > rhs ? .orderedAscending : .orderedDescending
  }
}

public enum ShelfTOCObservation: Equatable, Sendable {
  case grew(by: Int)
  case unchanged
  case shrank(by: Int)
}

public struct ShelfChapterStatus: Equatable, Sendable {
  public private(set) var totalChapterCount: Int
  public private(set) var currentChapterIndex: Int
  public private(set) var latestCheckCount: Int
  public private(set) var latestChapterTime: Int64
  public private(set) var lastReadTime: Int64

  public init(
    totalChapterCount: Int,
    currentChapterIndex: Int,
    latestCheckCount: Int,
    latestChapterTime: Int64,
    lastReadTime: Int64
  ) {
    self.totalChapterCount = max(0, totalChapterCount)
    self.currentChapterIndex = max(0, currentChapterIndex)
    self.latestCheckCount = max(0, latestCheckCount)
    self.latestChapterTime = latestChapterTime
    self.lastReadTime = lastReadTime
  }

  public var unreadChapterCount: Int {
    max(totalChapterCount - currentChapterIndex - 1, 0)
  }

  @discardableResult
  public mutating func observeTOC(
    chapterCount: Int,
    at milliseconds: Int64
  ) -> ShelfTOCObservation {
    let normalized = max(0, chapterCount)
    let previous = totalChapterCount
    totalChapterCount = normalized
    if normalized > previous {
      let growth = normalized - previous
      latestCheckCount = growth
      latestChapterTime = milliseconds
      return .grew(by: growth)
    }
    if normalized < previous {
      return .shrank(by: previous - normalized)
    }
    return .unchanged
  }

  public mutating func markRead(
    chapterIndex: Int,
    at milliseconds: Int64
  ) {
    currentChapterIndex = max(0, chapterIndex)
    latestCheckCount = 0
    lastReadTime = milliseconds
  }
}
