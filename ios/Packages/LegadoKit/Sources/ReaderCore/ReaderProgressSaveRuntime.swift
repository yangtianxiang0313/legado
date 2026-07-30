import LibraryDomain

public struct ReaderSessionGeneration:
  RawRepresentable, Equatable, Hashable, Sendable
{
  public let rawValue: UInt64

  public init(rawValue: UInt64) {
    self.rawValue = rawValue
  }
}

public struct ReaderProgressSessionIdentity:
  Equatable, Hashable, Sendable
{
  public let bookID: String
  public let sessionID: String
  public let generation: ReaderSessionGeneration

  public init(
    bookID: String,
    sessionID: String,
    generation: ReaderSessionGeneration
  ) {
    self.bookID = bookID
    self.sessionID = sessionID
    self.generation = generation
  }
}

public struct ReaderProgressSaveCommand:
  Equatable, Sendable
{
  public let identity: ReaderProgressSessionIdentity
  public let sequence: UInt64
  public let event: ReaderProgressSaveEvent
  public let snapshot: ReaderProgressSnapshot

  public init(
    identity: ReaderProgressSessionIdentity,
    sequence: UInt64,
    event: ReaderProgressSaveEvent,
    snapshot: ReaderProgressSnapshot
  ) {
    self.identity = identity
    self.sequence = sequence
    self.event = event
    self.snapshot = snapshot
  }
}

public enum ReaderProgressSaveDisposition:
  Equatable, Sendable
{
  case persisted
  case rejectedStaleGeneration(current: ReaderSessionGeneration?)
}

public protocol ReaderProgressPersistencePort: Sendable {
  func persist(
    _ command: ReaderProgressSaveCommand
  ) async throws -> ReaderProgressSaveDisposition

  func flush(
    _ identity: ReaderProgressSessionIdentity
  ) async throws
}

public struct ReaderProgressSaveExecutor: Sendable {
  private let persistence: any ReaderProgressPersistencePort

  public init(persistence: any ReaderProgressPersistencePort) {
    self.persistence = persistence
  }

  public func persist(
    _ command: ReaderProgressSaveCommand
  ) async throws -> ReaderProgressSaveDisposition {
    try await persistence.persist(command)
  }

  public func flush(
    _ identity: ReaderProgressSessionIdentity
  ) async throws {
    try await persistence.flush(identity)
  }
}

public struct ReaderProgressSessionState: Equatable, Sendable {
  public let identity: ReaderProgressSessionIdentity
  public private(set) var snapshot: ReaderProgressSnapshot
  private var nextSequence: UInt64

  public init(
    identity: ReaderProgressSessionIdentity,
    snapshot: ReaderProgressSnapshot,
    nextSequence: UInt64 = 1
  ) {
    self.identity = identity
    self.snapshot = snapshot
    self.nextSequence = max(nextSequence, 1)
  }

  @discardableResult
  public mutating func captureSave(
    runtimePosition: ReadingPosition,
    event: ReaderProgressSaveEvent,
    nowMilliseconds: Int64,
    resolvedChapterTitle: String?
  ) -> ReaderProgressSaveCommand {
    snapshot = AndroidReaderProgressCompatibility.saving(
      stored: snapshot,
      runtimePosition: runtimePosition,
      event: event,
      nowMilliseconds: nowMilliseconds,
      resolvedChapterTitle: resolvedChapterTitle
    )
    let command = ReaderProgressSaveCommand(
      identity: identity,
      sequence: nextSequence,
      event: event,
      snapshot: snapshot
    )
    nextSequence = nextSequence == UInt64.max ? 1 : nextSequence + 1
    return command
  }
}

public struct AndroidReaderProgressRuntimeState:
  Equatable, Sendable
{
  public let bookID: String
  public let position: ReadingPosition

  public init(bookID: String, position: ReadingPosition) {
    self.bookID = bookID
    self.position = position
  }
}

public struct AndroidReaderProgressSaveExecution:
  Equatable, Sendable
{
  public let bookID: String
  public let snapshot: ReaderProgressSnapshot

  public init(
    bookID: String,
    snapshot: ReaderProgressSnapshot
  ) {
    self.bookID = bookID
    self.snapshot = snapshot
  }
}

public struct AndroidQueuedReaderProgressSave:
  Equatable, Sendable
{
  public let event: ReaderProgressSaveEvent

  public init(event: ReaderProgressSaveEvent) {
    self.event = event
  }

  public func execute(
    runtime: AndroidReaderProgressRuntimeState?,
    stored: ReaderProgressSnapshot,
    nowMilliseconds: Int64,
    resolvedChapterTitle: String?
  ) -> AndroidReaderProgressSaveExecution? {
    guard let runtime else {
      return nil
    }
    return AndroidReaderProgressSaveExecution(
      bookID: runtime.bookID,
      snapshot: AndroidReaderProgressCompatibility.saving(
        stored: stored,
        runtimePosition: runtime.position,
        event: event,
        nowMilliseconds: nowMilliseconds,
        resolvedChapterTitle: resolvedChapterTitle
      )
    )
  }
}
