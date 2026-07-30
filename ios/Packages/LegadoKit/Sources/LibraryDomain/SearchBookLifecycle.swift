public struct SearchBookCandidate: Equatable, Sendable {
  public let name: String
  public let author: String
  public let bookURL: String
  public let origin: String
  public let originOrder: Int
  public let observedAt: Int64

  public init(
    name: String,
    author: String,
    bookURL: String,
    origin: String,
    originOrder: Int = 0,
    observedAt: Int64 = 0
  ) {
    self.name = name
    self.author = author
    self.bookURL = bookURL
    self.origin = origin
    self.originOrder = originOrder
    self.observedAt = observedAt
  }
}

public struct SearchBookAggregate: Equatable, Sendable {
  public let representative: SearchBookCandidate
  public private(set) var origins: [String]

  public init(representative: SearchBookCandidate) {
    self.representative = representative
    self.origins = [representative.origin]
  }

  mutating func addOrigin(_ origin: String) {
    guard !origins.contains(origin) else { return }
    origins.append(origin)
  }
}

public struct SearchBookSearchState: Equatable, Sendable {
  public private(set) var books: [SearchBookAggregate]

  public init(books: [SearchBookAggregate] = []) {
    self.books = books
  }

  public mutating func merge(
    _ candidates: [SearchBookCandidate],
    keyword: String,
    precision: Bool
  ) {
    guard !candidates.isEmpty else { return }

    var exact: [RankedAggregate] = []
    var contains: [RankedAggregate] = []
    var other: [RankedAggregate] = []
    var nextRank = 0

    for book in books {
      let ranked = RankedAggregate(rank: nextRank, value: book)
      nextRank += 1
      switch Self.group(for: book.representative, keyword: keyword) {
      case .exact:
        exact.append(ranked)
      case .contains:
        contains.append(ranked)
      case .other:
        other.append(ranked)
      }
    }

    for candidate in candidates {
      let group = Self.group(for: candidate, keyword: keyword)
      if precision, group == .other {
        continue
      }
      switch group {
      case .exact:
        Self.merge(candidate, into: &exact, nextRank: &nextRank)
      case .contains:
        Self.merge(candidate, into: &contains, nextRank: &nextRank)
      case .other:
        Self.merge(candidate, into: &other, nextRank: &nextRank)
      }
    }

    exact.sort(by: Self.moreOriginsFirst)
    contains.sort(by: Self.moreOriginsFirst)
    books = exact.map(\.value) + contains.map(\.value)
    if !precision {
      books.append(contentsOf: other.map(\.value))
    }
  }

  public static func aggregate(
    batches: [[SearchBookCandidate]],
    keyword: String,
    precision: Bool
  ) -> [SearchBookAggregate] {
    var state = Self()
    for batch in batches {
      state.merge(batch, keyword: keyword, precision: precision)
    }
    return state.books
  }

  private enum MatchGroup {
    case exact
    case contains
    case other
  }

  private struct RankedAggregate {
    let rank: Int
    var value: SearchBookAggregate
  }

  private static func group(
    for candidate: SearchBookCandidate,
    keyword: String
  ) -> MatchGroup {
    if candidate.name == keyword || candidate.author == keyword {
      return .exact
    }
    if candidate.name.contains(keyword) || candidate.author.contains(keyword) {
      return .contains
    }
    return .other
  }

  private static func merge(
    _ candidate: SearchBookCandidate,
    into books: inout [RankedAggregate],
    nextRank: inout Int
  ) {
    if let index = books.firstIndex(where: {
      $0.value.representative.name == candidate.name
        && $0.value.representative.author == candidate.author
    }) {
      books[index].value.addOrigin(candidate.origin)
      return
    }
    books.append(
      RankedAggregate(
        rank: nextRank,
        value: SearchBookAggregate(representative: candidate)
      )
    )
    nextRank += 1
  }

  private static func moreOriginsFirst(
    _ lhs: RankedAggregate,
    _ rhs: RankedAggregate
  ) -> Bool {
    if lhs.value.origins.count != rhs.value.origins.count {
      return lhs.value.origins.count > rhs.value.origins.count
    }
    return lhs.rank < rhs.rank
  }
}

public struct SearchBookWriteReceipt: Equatable, Sendable {
  public let sequence: Int64

  public init(sequence: Int64) {
    self.sequence = sequence
  }
}

public struct SearchBookCandidateStore: Equatable, Sendable {
  public private(set) var candidates: [SearchBookCandidate]
  public private(set) var sourceIDs: [String]
  private var nextWriteSequence: Int64

  public init(
    candidates: [SearchBookCandidate] = [],
    sourceIDs: [String] = [],
    nextWriteSequence: Int64 = 1
  ) {
    self.candidates = []
    self.sourceIDs = []
    self.nextWriteSequence = nextWriteSequence
    for sourceID in sourceIDs {
      registerSource(sourceID)
    }
    for candidate in candidates {
      _ = insert(candidate)
    }
  }

  public mutating func registerSource(_ sourceID: String) {
    guard !sourceIDs.contains(sourceID) else { return }
    sourceIDs.append(sourceID)
  }

  @discardableResult
  public mutating func insert(
    _ candidate: SearchBookCandidate
  ) -> SearchBookWriteReceipt {
    if let index = candidates.firstIndex(where: {
      $0.bookURL == candidate.bookURL
    }) {
      candidates[index] = candidate
    } else {
      candidates.append(candidate)
    }
    defer { nextWriteSequence += 1 }
    return SearchBookWriteReceipt(sequence: nextWriteSequence)
  }

  public func candidate(bookURL: String) -> SearchBookCandidate? {
    candidates.first(where: { $0.bookURL == bookURL })
  }

  public mutating func removeSource(_ sourceID: String) {
    sourceIDs.removeAll(where: { $0 == sourceID })
    candidates.removeAll(where: { $0.origin == sourceID })
  }

  public mutating func clearExpired(earlierThan threshold: Int64) {
    candidates.removeAll(where: { $0.observedAt < threshold })
  }
}
