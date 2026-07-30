public struct ReaderLoadGeneration:
  RawRepresentable, Equatable, Hashable, Sendable
{
  public let rawValue: UInt64

  public init(rawValue: UInt64) {
    self.rawValue = rawValue
  }
}

public struct ReaderLoadToken: Equatable, Hashable, Sendable {
  public let generation: ReaderLoadGeneration
  public let chapterIndex: Int
  public let nonce: UInt64

  public init(
    generation: ReaderLoadGeneration,
    chapterIndex: Int,
    nonce: UInt64
  ) {
    self.generation = generation
    self.chapterIndex = chapterIndex
    self.nonce = nonce
  }
}

public enum ReaderLoadSlot: Equatable, Sendable {
  case previous
  case current
  case next
}

public enum ReaderLoadAdmission: Equatable, Sendable {
  case accepted(ReaderLoadSlot)
  case rejectedStale
  case rejectedOutsideWindow
}

public struct ReaderLoadRegistry: Equatable, Sendable {
  public private(set) var generation: ReaderLoadGeneration
  private var activeByIndex: [Int: ReaderLoadToken]
  private var nextNonce: UInt64

  public init() {
    self.generation = ReaderLoadGeneration(rawValue: 1)
    self.activeByIndex = [:]
    self.nextNonce = 1
  }

  @discardableResult
  public mutating func beginSession() -> ReaderLoadGeneration {
    generation = ReaderLoadGeneration(
      rawValue: increment(generation.rawValue)
    )
    activeByIndex.removeAll(keepingCapacity: true)
    return generation
  }

  public mutating func acquire(
    chapterIndex: Int
  ) -> ReaderLoadToken? {
    guard activeByIndex[chapterIndex] == nil else { return nil }
    let token = ReaderLoadToken(
      generation: generation,
      chapterIndex: chapterIndex,
      nonce: nextNonce
    )
    nextNonce = increment(nextNonce)
    activeByIndex[chapterIndex] = token
    return token
  }

  @discardableResult
  public mutating func finish(_ token: ReaderLoadToken) -> Bool {
    guard activeByIndex[token.chapterIndex] == token else {
      return false
    }
    activeByIndex[token.chapterIndex] = nil
    return true
  }

  public mutating func admit(
    _ token: ReaderLoadToken,
    currentChapterIndex: Int
  ) -> ReaderLoadAdmission {
    guard finish(token) else {
      return .rejectedStale
    }
    if token.chapterIndex == currentChapterIndex {
      return .accepted(.current)
    }
    if currentChapterIndex != Int.min,
      token.chapterIndex == currentChapterIndex - 1
    {
      return .accepted(.previous)
    }
    if currentChapterIndex != Int.max,
      token.chapterIndex == currentChapterIndex + 1
    {
      return .accepted(.next)
    }
    return .rejectedOutsideWindow
  }

  public func activeToken(
    for chapterIndex: Int
  ) -> ReaderLoadToken? {
    activeByIndex[chapterIndex]
  }

  public var activeChapterIndices: [Int] {
    activeByIndex.keys.sorted()
  }

  private func increment(_ value: UInt64) -> UInt64 {
    value == UInt64.max ? 1 : value + 1
  }
}
