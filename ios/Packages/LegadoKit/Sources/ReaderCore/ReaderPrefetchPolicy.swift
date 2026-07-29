public enum ReaderPrefetchDirection: String, Equatable, Hashable, Sendable {
  case forward
  case backward
}

public struct ReaderPrefetchFailure: Equatable, Hashable, Sendable {
  public let chapterIndex: Int
  public let count: Int

  public init(chapterIndex: Int, count: Int) {
    self.chapterIndex = chapterIndex
    self.count = count
  }
}

public struct ReaderPrefetchPolicyInput: Equatable, Sendable {
  public let isLocalBook: Bool
  public let chapterCount: Int
  public let currentChapterIndex: Int
  public let configuredCount: Int
  public let completedChapterIndices: Set<Int>
  public let failures: [ReaderPrefetchFailure]

  public init(
    isLocalBook: Bool,
    chapterCount: Int,
    currentChapterIndex: Int,
    configuredCount: Int,
    completedChapterIndices: Set<Int>,
    failures: [ReaderPrefetchFailure]
  ) {
    self.isLocalBook = isLocalBook
    self.chapterCount = chapterCount
    self.currentChapterIndex = currentChapterIndex
    self.configuredCount = configuredCount
    self.completedChapterIndices = completedChapterIndices
    self.failures = failures
  }
}

public struct ReaderPrefetchCommand: Equatable, Hashable, Sendable {
  public let chapterIndex: Int
  public let direction: ReaderPrefetchDirection

  public init(
    chapterIndex: Int,
    direction: ReaderPrefetchDirection
  ) {
    self.chapterIndex = chapterIndex
    self.direction = direction
  }
}

public struct ReaderPrefetchPlan: Equatable, Sendable {
  public let taskCreated: Bool
  public let forward: [ReaderPrefetchCommand]
  public let backward: [ReaderPrefetchCommand]

  public init(
    taskCreated: Bool,
    forward: [ReaderPrefetchCommand],
    backward: [ReaderPrefetchCommand]
  ) {
    self.taskCreated = taskCreated
    self.forward = forward
    self.backward = backward
  }

  public var commands: [ReaderPrefetchCommand] {
    forward + backward
  }

  public var workerCount: Int {
    taskCreated ? 2 : 0
  }

  public var initialChapterIndices: [Int] {
    [forward.first, backward.first]
      .compactMap { $0?.chapterIndex }
      .sorted()
  }
}

public enum AndroidReaderPrefetchPolicy {
  public static func plan(
    for input: ReaderPrefetchPolicyInput
  ) -> ReaderPrefetchPlan {
    guard !input.isLocalBook, input.configuredCount >= 2 else {
      return ReaderPrefetchPlan(
        taskCreated: false,
        forward: [],
        backward: []
      )
    }

    let chapterCount = max(input.chapterCount, 0)
    let lastChapterIndex = chapterCount - 1
    let forwardEnd = min(
      saturatedAdd(
        input.currentChapterIndex,
        input.configuredCount
      ),
      lastChapterIndex
    )
    let backwardEnd = max(
      saturatedSubtract(
        input.currentChapterIndex,
        min(5, input.configuredCount)
      ),
      0
    )
    let failed = Dictionary(
      input.failures.map { ($0.chapterIndex, $0.count) },
      uniquingKeysWith: { _, latest in latest }
    )

    let forward = candidates(
      from: saturatedAdd(input.currentChapterIndex, 2),
      through: forwardEnd,
      direction: .forward
    )
    .filter {
      isEligible(
        $0.chapterIndex,
        chapterCount: chapterCount,
        completed: input.completedChapterIndices,
        failures: failed
      )
    }
    let backward = candidates(
      from: saturatedSubtract(input.currentChapterIndex, 2),
      through: backwardEnd,
      direction: .backward
    )
    .filter {
      isEligible(
        $0.chapterIndex,
        chapterCount: chapterCount,
        completed: input.completedChapterIndices,
        failures: failed
      )
    }
    return ReaderPrefetchPlan(
      taskCreated: true,
      forward: forward,
      backward: backward
    )
  }

  private static func candidates(
    from start: Int,
    through end: Int,
    direction: ReaderPrefetchDirection
  ) -> [ReaderPrefetchCommand] {
    switch direction {
    case .forward:
      guard start <= end else { return [] }
      return (start...end).map {
        ReaderPrefetchCommand(
          chapterIndex: $0,
          direction: direction
        )
      }
    case .backward:
      guard start >= end else { return [] }
      return stride(from: start, through: end, by: -1).map {
        ReaderPrefetchCommand(
          chapterIndex: $0,
          direction: direction
        )
      }
    }
  }

  private static func isEligible(
    _ chapterIndex: Int,
    chapterCount: Int,
    completed: Set<Int>,
    failures: [Int: Int]
  ) -> Bool {
    chapterIndex >= 0
      && chapterIndex < chapterCount
      && !completed.contains(chapterIndex)
      && failures[chapterIndex, default: 0] < 3
  }

  private static func saturatedAdd(
    _ lhs: Int,
    _ rhs: Int
  ) -> Int {
    let (value, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? (rhs >= 0 ? Int.max : Int.min) : value
  }

  private static func saturatedSubtract(
    _ lhs: Int,
    _ rhs: Int
  ) -> Int {
    let (value, overflow) = lhs.subtractingReportingOverflow(rhs)
    return overflow ? (rhs >= 0 ? Int.min : Int.max) : value
  }
}

public struct ReaderPrefetchGenerationID:
  RawRepresentable, Equatable, Hashable, Sendable
{
  public let rawValue: UInt64

  public init(rawValue: UInt64) {
    self.rawValue = rawValue
  }
}

public struct ReaderPrefetchGeneration: Equatable, Sendable {
  public let id: ReaderPrefetchGenerationID
  public let currentChapterIndex: Int
  public let plan: ReaderPrefetchPlan

  public init(
    id: ReaderPrefetchGenerationID,
    currentChapterIndex: Int,
    plan: ReaderPrefetchPlan
  ) {
    self.id = id
    self.currentChapterIndex = currentChapterIndex
    self.plan = plan
  }
}

public struct ReaderPrefetchGenerationTransition: Equatable, Sendable {
  public let cancelled: ReaderPrefetchGeneration?
  public let replacement: ReaderPrefetchGeneration?

  public init(
    cancelled: ReaderPrefetchGeneration?,
    replacement: ReaderPrefetchGeneration?
  ) {
    self.cancelled = cancelled
    self.replacement = replacement
  }
}

public struct ReaderPrefetchGenerationState: Equatable, Sendable {
  public private(set) var active: ReaderPrefetchGeneration?
  private var nextID: UInt64

  public init() {
    self.active = nil
    self.nextID = 1
  }

  @discardableResult
  public mutating func replace(
    using input: ReaderPrefetchPolicyInput
  ) -> ReaderPrefetchGenerationTransition {
    let plan = AndroidReaderPrefetchPolicy.plan(for: input)
    guard plan.taskCreated else {
      return ReaderPrefetchGenerationTransition(
        cancelled: nil,
        replacement: nil
      )
    }
    let cancelled = active
    let replacement = ReaderPrefetchGeneration(
      id: ReaderPrefetchGenerationID(rawValue: nextID),
      currentChapterIndex: input.currentChapterIndex,
      plan: plan
    )
    nextID = nextID == UInt64.max ? 1 : nextID + 1
    active = replacement
    return ReaderPrefetchGenerationTransition(
      cancelled: cancelled,
      replacement: replacement
    )
  }
}
