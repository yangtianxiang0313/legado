import LibraryDomain
@testable import AppUseCases
import ReaderCore
import XCTest

@MainActor
final class ReadAloudSessionTests: XCTestCase {
  func testSessionStartsPausesResumesAndStops() {
    let synthesizer = FakeSystemSpeechSynthesizer()
    let session = ReadAloudSession(synthesizer: synthesizer)
    let document = makeDocument(content: "第一段\n\n第二段")

    session.start(document: document, relativeRate: 2) {}

    XCTAssertEqual(session.state, .speaking)
    XCTAssertEqual(synthesizer.spokenSegments.map(\.text), ["第一段", "第二段"])
    XCTAssertEqual(synthesizer.relativeRate, 2)
    session.pause()
    XCTAssertEqual(session.state, .paused)
    XCTAssertEqual(synthesizer.pauseCount, 1)
    session.resume()
    XCTAssertEqual(session.state, .speaking)
    XCTAssertEqual(synthesizer.resumeCount, 1)
    session.stop()
    XCTAssertEqual(session.state, .idle)
    XCTAssertNil(session.bookID)
    XCTAssertEqual(synthesizer.stopCount, 2)
  }

  func testLastSegmentRequestsNextChapterAndContinues() {
    let synthesizer = FakeSystemSpeechSynthesizer()
    let session = ReadAloudSession(synthesizer: synthesizer)
    var nextChapterRequests = 0
    let first = makeDocument(content: "第一段")

    session.start(document: first) {
      nextChapterRequests += 1
    }
    let segment = try! XCTUnwrap(synthesizer.spokenSegments.first)
    synthesizer.emit(.started(segmentID: segment.id))
    synthesizer.emit(.finished(segmentID: segment.id))

    XCTAssertEqual(session.state, .awaitingNextChapter)
    XCTAssertEqual(session.characterOffset, segment.endOffset)
    XCTAssertEqual(nextChapterRequests, 1)

    let second = ReaderDocument(
      position: ReaderPosition(
        bookID: first.position.bookID,
        chapterID: ChapterID(rawValue: "chapter-2"),
        chapterIndex: 1,
        characterOffset: 0
      ),
      title: "第二章",
      content: "下一章"
    )
    session.continueWithNextChapter(document: second) {}

    XCTAssertEqual(session.state, .speaking)
    XCTAssertEqual(session.chapterID, second.position.chapterID)
    XCTAssertEqual(synthesizer.spokenSegments.map(\.text), ["下一章"])
  }

  private func makeDocument(content: String) -> ReaderDocument {
    ReaderDocument(
      position: ReaderPosition(
        bookID: BookID(rawValue: "book"),
        chapterID: ChapterID(rawValue: "chapter-1"),
        chapterIndex: 0,
        characterOffset: 0
      ),
      title: "第一章",
      content: content
    )
  }
}

@MainActor
private final class FakeSystemSpeechSynthesizer:
  SystemSpeechSynthesizing
{
  var spokenSegments: [ReadAloudSegment] = []
  var pauseCount = 0
  var resumeCount = 0
  var stopCount = 0
  var relativeRate: Float = 0
  private var onEvent:
    (@MainActor @Sendable (SystemSpeechEvent) -> Void)?

  func speak(
    _ segments: [ReadAloudSegment],
    relativeRate: Float,
    onEvent: @escaping @MainActor @Sendable (SystemSpeechEvent) -> Void
  ) {
    spokenSegments = segments
    self.relativeRate = relativeRate
    self.onEvent = onEvent
  }

  func pause() {
    pauseCount += 1
  }

  func resume() {
    resumeCount += 1
  }

  func stop() {
    stopCount += 1
  }

  func emit(_ event: SystemSpeechEvent) {
    onEvent?(event)
  }
}
