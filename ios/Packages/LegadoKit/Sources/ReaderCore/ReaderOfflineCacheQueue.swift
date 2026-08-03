public struct ReaderOfflineCacheModelID:
  RawRepresentable, Equatable, Hashable, Sendable
{
  public let rawValue: UInt64

  public init(rawValue: UInt64) {
    self.rawValue = rawValue
  }
}

public struct ReaderOfflineCacheModelState: Equatable, Sendable {
  public let id: ReaderOfflineCacheModelID
  public let bookID: String
  public private(set) var waitingChapterIndices: [Int]
  public private(set) var downloadingChapterIndices: [Int]
  public private(set) var failureCounts: [Int: Int]
  public private(set) var failedCount: Int
  public private(set) var successCount: Int
  public private(set) var isRun: Bool
  public private(set) var isStop: Bool

  public init(id: ReaderOfflineCacheModelID, bookID: String) {
    self.id = id
    self.bookID = bookID
    self.waitingChapterIndices = []
    self.downloadingChapterIndices = []
    self.failureCounts = [:]
    self.failedCount = 0
    self.successCount = 0
    self.isRun = false
    self.isStop = false
  }

  public var waitCount: Int { waitingChapterIndices.count }
  public var onDownloadCount: Int { downloadingChapterIndices.count }

  fileprivate mutating func enqueue(_ chapterIndex: Int) {
    guard !waitingChapterIndices.contains(chapterIndex),
      !downloadingChapterIndices.contains(chapterIndex)
    else { return }
    waitingChapterIndices.append(chapterIndex)
    waitingChapterIndices.sort()
    isRun = true
  }

  fileprivate mutating func begin(_ chapterIndex: Int) {
    waitingChapterIndices.removeAll { $0 == chapterIndex }
    guard !downloadingChapterIndices.contains(chapterIndex) else { return }
    downloadingChapterIndices.append(chapterIndex)
    downloadingChapterIndices.sort()
    isRun = true
  }

  fileprivate mutating func finish(_ chapterIndex: Int) {
    downloadingChapterIndices.removeAll { $0 == chapterIndex }
  }

  fileprivate mutating func recordTerminalSuccess() {
    successCount += 1
  }

  fileprivate mutating func recordTerminalFailure() {
    failedCount += 1
  }

  fileprivate mutating func incrementFailureCount(
    for chapterIndex: Int
  ) -> Int {
    let count = failureCounts[chapterIndex, default: 0] + 1
    failureCounts[chapterIndex] = count
    return count
  }

  fileprivate mutating func clearResults() {
    failureCounts.removeAll(keepingCapacity: true)
    failedCount = 0
    successCount = 0
  }

  fileprivate mutating func stop() {
    isStop = true
  }

  fileprivate mutating func close() {
    waitingChapterIndices.removeAll(keepingCapacity: true)
    isStop = true
  }
}

public enum ReaderOfflineCacheFailureKind: Equatable, Sendable {
  case ordinary
  case concurrent
}

public struct ReaderOfflineCacheFailureTransition: Equatable, Sendable {
  public let errorCount: Int
  public let waitingDuringBackoff: Bool
  public let requeued: Bool
  public let state: ReaderOfflineCacheModelState

  public init(
    errorCount: Int,
    waitingDuringBackoff: Bool,
    requeued: Bool,
    state: ReaderOfflineCacheModelState
  ) {
    self.errorCount = errorCount
    self.waitingDuringBackoff = waitingDuringBackoff
    self.requeued = requeued
    self.state = state
  }
}

public struct ReaderOfflineCacheSummary: Equatable, Sendable {
  public let downloadingCount: Int
  public let waitingCount: Int
  public let failedCount: Int
  public let successCount: Int

  public init(
    downloadingCount: Int,
    waitingCount: Int,
    failedCount: Int,
    successCount: Int
  ) {
    self.downloadingCount = downloadingCount
    self.waitingCount = waitingCount
    self.failedCount = failedCount
    self.successCount = successCount
  }

  public var androidDisplayText: String {
    "正在下载:\(downloadingCount)|等待中:\(waitingCount)|失败:\(failedCount)|成功:\(successCount)"
  }
}

/// Platform-neutral state machine for Android's global offline-cache models.
/// Persistence, scheduling and UI observe this value through adapters.
public struct ReaderOfflineCacheQueue: Equatable, Sendable {
  private var models: [ReaderOfflineCacheModelID: ReaderOfflineCacheModelState]
  private var modelIDByBook: [String: ReaderOfflineCacheModelID]
  private var nextID: UInt64

  public init() {
    self.models = [:]
    self.modelIDByBook = [:]
    self.nextID = 1
  }

  public var registeredModelCount: Int { models.count }

  public var summary: ReaderOfflineCacheSummary {
    ReaderOfflineCacheSummary(
      downloadingCount: models.values.reduce(0) { $0 + $1.onDownloadCount },
      waitingCount: models.values.reduce(0) { $0 + $1.waitCount },
      failedCount: models.values.reduce(0) { $0 + $1.failedCount },
      successCount: models.values.reduce(0) { $0 + $1.successCount }
    )
  }

  @discardableResult
  public mutating func register(bookID: String) -> ReaderOfflineCacheModelID {
    if let existing = modelIDByBook[bookID] { return existing }
    let id = ReaderOfflineCacheModelID(rawValue: nextID)
    nextID = nextID == UInt64.max ? 1 : nextID + 1
    models[id] = ReaderOfflineCacheModelState(id: id, bookID: bookID)
    modelIDByBook[bookID] = id
    return id
  }

  public func state(
    for id: ReaderOfflineCacheModelID
  ) -> ReaderOfflineCacheModelState? {
    models[id]
  }

  public mutating func enqueue(
    _ chapterIndices: some Sequence<Int>,
    for id: ReaderOfflineCacheModelID
  ) {
    guard var state = models[id], !state.isStop else { return }
    for index in chapterIndices { state.enqueue(index) }
    models[id] = state
  }

  public mutating func begin(
    _ chapterIndex: Int,
    for id: ReaderOfflineCacheModelID
  ) {
    guard var state = models[id], !state.isStop else { return }
    state.begin(chapterIndex)
    models[id] = state
  }

  public mutating func recordTerminalSuccess(
    for id: ReaderOfflineCacheModelID
  ) {
    guard var state = models[id] else { return }
    state.recordTerminalSuccess()
    models[id] = state
  }

  public mutating func recordTerminalFailure(
    for id: ReaderOfflineCacheModelID
  ) {
    guard var state = models[id] else { return }
    state.recordTerminalFailure()
    models[id] = state
  }

  @discardableResult
  public mutating func fail(
    _ chapterIndex: Int,
    kind: ReaderOfflineCacheFailureKind,
    for id: ReaderOfflineCacheModelID
  ) -> ReaderOfflineCacheFailureTransition? {
    guard var state = models[id] else { return nil }
    state.finish(chapterIndex)
    let errorCount: Int
    switch kind {
    case .ordinary:
      errorCount = state.incrementFailureCount(for: chapterIndex)
    case .concurrent:
      errorCount = state.failureCounts[chapterIndex, default: 0]
    }
    let shouldRequeue = !state.isStop && (kind == .concurrent || errorCount < 3)
    if shouldRequeue { state.enqueue(chapterIndex) }
    if kind == .ordinary && errorCount >= 3 { state.stop() }
    models[id] = state
    return ReaderOfflineCacheFailureTransition(
      errorCount: errorCount,
      waitingDuringBackoff: true,
      requeued: shouldRequeue,
      state: state
    )
  }

  public mutating func stop(_ id: ReaderOfflineCacheModelID) {
    guard var state = models[id] else { return }
    state.stop()
    models[id] = state
  }

  public mutating func clearResults() {
    for id in models.keys {
      models[id]?.clearResults()
    }
  }

  @discardableResult
  public mutating func close(
    _ id: ReaderOfflineCacheModelID
  ) -> ReaderOfflineCacheModelState? {
    guard var state = models.removeValue(forKey: id) else { return nil }
    modelIDByBook[state.bookID] = nil
    state.close()
    return state
  }
}
