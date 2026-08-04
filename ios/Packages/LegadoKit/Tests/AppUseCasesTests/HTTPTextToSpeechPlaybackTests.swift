import AppUseCases
import LibraryDomain
import ReaderCore
import XCTest

@MainActor
final class HTTPTextToSpeechPlaybackTests: XCTestCase {
  func testImportedEngineSelectionPersistsAndFallsBackWhenRemoved() async {
    let repository = PlaybackEngineRepository(engines: [
      HTTPTextToSpeechEngine(
        id: 42,
        name: "Android HTTP TTS",
        url: "https://tts.example.com/audio"
      )
    ])
    let persistence = PlaybackSelectionPersistence()
    let store = HTTPTextToSpeechEngineStore(
      repository: repository,
      persistence: persistence
    )

    await store.reload()
    store.select(42)

    XCTAssertEqual(store.selectedEngine?.name, "Android HTTP TTS")
    XCTAssertEqual(persistence.value, 42)

    await repository.replace(with: [])
    await store.reload()
    XCTAssertNil(store.selectedEngineID)
    XCTAssertNil(persistence.value)
  }

  func testBookSelectionOverridesGlobalAndInvalidAndroidValuesUseSystem()
    async
  {
    let repository = PlaybackEngineRepository(engines: [
      HTTPTextToSpeechEngine(
        id: 42,
        name: "Book HTTP TTS",
        url: "https://tts.example.com/book"
      ),
      HTTPTextToSpeechEngine(
        id: 7,
        name: "Global HTTP TTS",
        url: "https://tts.example.com/global"
      ),
    ])
    let store = HTTPTextToSpeechEngineStore(
      repository: repository,
      persistence: PlaybackSelectionPersistence()
    )
    await store.reload()
    store.select(7)

    store.applyBookSelection("42")
    XCTAssertEqual(store.effectiveEngine?.id, 42)

    store.applyBookSelection(nil)
    XCTAssertEqual(store.effectiveEngine?.id, 7)

    store.applyBookSelection("")
    XCTAssertNil(store.effectiveEngine)
    store.applyBookSelection("999")
    XCTAssertNil(store.effectiveEngine)
    store.applyBookSelection(#"{"value":"android.system.tts"}"#)
    XCTAssertNil(store.effectiveEngine)
  }

  func testReadAloudStateMachineKeepsPauseResumeAndSegmentProgress() {
    let synthesizer = PlaybackSynthesizer()
    let session = ReadAloudSession(synthesizer: synthesizer)
    let document = ReaderDocument(
      position: ReaderPosition(
        bookID: BookID(rawValue: "book"),
        chapterID: ChapterID(rawValue: "chapter"),
        chapterIndex: 0,
        characterOffset: 0
      ),
      title: "第一章",
      content: "第一段。\n第二段。"
    )

    session.start(document: document, requestNextChapter: {})
    XCTAssertEqual(session.state, .speaking)
    session.pause()
    XCTAssertEqual(session.state, .paused)
    session.resume()
    XCTAssertEqual(session.state, .speaking)

    synthesizer.finishAll()
    XCTAssertEqual(session.state, .awaitingNextChapter)
    XCTAssertEqual(session.characterOffset, document.content.count)
  }
}

private actor PlaybackEngineRepository: HTTPTextToSpeechRepository {
  private var engines: [HTTPTextToSpeechEngine]

  init(engines: [HTTPTextToSpeechEngine]) { self.engines = engines }

  func httpTextToSpeechEngines() async throws -> [HTTPTextToSpeechEngine] {
    engines
  }

  func upsertHTTPTextToSpeechEngine(
    _ engine: HTTPTextToSpeechEngine
  ) async throws {
    engines.removeAll { $0.id == engine.id }
    engines.append(engine)
  }

  func replace(with values: [HTTPTextToSpeechEngine]) {
    engines = values
  }
}

@MainActor
private final class PlaybackSelectionPersistence:
  HTTPTextToSpeechSelectionPersistence
{
  var value: Int64?

  func selectedHTTPTextToSpeechEngineID() -> Int64? { value }
  func saveSelectedHTTPTextToSpeechEngineID(_ id: Int64?) { value = id }
}

@MainActor
private final class PlaybackSynthesizer: SystemSpeechSynthesizing {
  private var segments: [ReadAloudSegment] = []
  private var onEvent: (@MainActor @Sendable (SystemSpeechEvent) -> Void)?

  func speak(
    _ segments: [ReadAloudSegment],
    relativeRate: Float,
    onEvent: @escaping @MainActor @Sendable (SystemSpeechEvent) -> Void
  ) {
    self.segments = segments
    self.onEvent = onEvent
    if let first = segments.first { onEvent(.started(segmentID: first.id)) }
  }

  func pause() {}
  func resume() {}
  func stop() { segments = [] }

  func finishAll() {
    for segment in segments {
      onEvent?(.finished(segmentID: segment.id))
    }
  }
}
