import LibraryDomain
import Observation
import ReaderCore

public enum SystemSpeechEvent: Equatable, Sendable {
  case started(segmentID: String)
  case finished(segmentID: String)
  case cancelled
  case failed(message: String)
}

@MainActor
public protocol SystemSpeechSynthesizing: AnyObject {
  func speak(
    _ segments: [ReadAloudSegment],
    relativeRate: Float,
    onEvent: @escaping @MainActor @Sendable (SystemSpeechEvent) -> Void
  )
  func pause()
  func resume()
  func stop()
}

public enum ReadAloudState: Equatable, Sendable {
  case idle
  case speaking
  case paused
  case awaitingNextChapter
  case finished
  case failed
}

@MainActor
@Observable
public final class ReadAloudSession {
  public private(set) var state: ReadAloudState = .idle
  public private(set) var bookID: BookID?
  public private(set) var chapterID: ChapterID?
  public private(set) var characterOffset = 0
  public private(set) var errorMessage: String?

  private let synthesizer: any SystemSpeechSynthesizing
  private var segments: [ReadAloudSegment] = []
  private var requestNextChapter: (@MainActor @Sendable () -> Void)?

  public init(synthesizer: any SystemSpeechSynthesizing) {
    self.synthesizer = synthesizer
  }

  public func start(
    document: ReaderDocument,
    relativeRate: Float = 1,
    requestNextChapter: @escaping @MainActor @Sendable () -> Void
  ) {
    synthesizer.stop()
    bookID = document.position.bookID
    chapterID = document.position.chapterID
    characterOffset = max(0, document.position.characterOffset)
    errorMessage = nil
    self.requestNextChapter = requestNextChapter
    speak(
      content: document.content,
      startingAt: characterOffset,
      relativeRate: relativeRate
    )
  }

  public func continueWithNextChapter(
    document: ReaderDocument,
    relativeRate: Float = 1,
    requestNextChapter: @escaping @MainActor @Sendable () -> Void
  ) {
    guard
      state == .awaitingNextChapter,
      document.position.bookID == bookID
    else { return }
    chapterID = document.position.chapterID
    characterOffset = max(0, document.position.characterOffset)
    self.requestNextChapter = requestNextChapter
    speak(
      content: document.content,
      startingAt: characterOffset,
      relativeRate: relativeRate
    )
  }

  public func pause() {
    guard state == .speaking else { return }
    synthesizer.pause()
    state = .paused
  }

  public func resume() {
    guard state == .paused else { return }
    synthesizer.resume()
    state = .speaking
  }

  public func stop() {
    synthesizer.stop()
    segments = []
    requestNextChapter = nil
    state = .idle
    bookID = nil
    chapterID = nil
    characterOffset = 0
    errorMessage = nil
  }

  public func finishAtEndOfBook() {
    guard state == .awaitingNextChapter else { return }
    segments = []
    requestNextChapter = nil
    state = .finished
  }

  private func speak(
    content: String,
    startingAt offset: Int,
    relativeRate: Float
  ) {
    segments = ReadAloudPlan.segments(
      content: content,
      startingAt: offset
    )
    guard !segments.isEmpty else {
      state = .awaitingNextChapter
      requestNextChapter?()
      return
    }
    state = .speaking
    synthesizer.speak(
      segments,
      relativeRate: relativeRate
    ) { [weak self] event in
      self?.handle(event)
    }
  }

  private func handle(_ event: SystemSpeechEvent) {
    switch event {
    case .started(let segmentID):
      if let segment = segments.first(where: { $0.id == segmentID }) {
        characterOffset = segment.startOffset
      }
    case .finished(let segmentID):
      guard
        let index = segments.firstIndex(where: { $0.id == segmentID })
      else { return }
      characterOffset = segments[index].endOffset
      if index == segments.index(before: segments.endIndex) {
        state = .awaitingNextChapter
        requestNextChapter?()
      }
    case .cancelled:
      if state != .idle {
        state = .paused
      }
    case .failed(let message):
      state = .failed
      errorMessage = message
    }
  }
}
