import AppUseCases
import IntegrationKit
import LibraryDomain
import XCTest

final class WebDAVReaderProgressUploadTests: XCTestCase {
  func testFlushUploadsOnlyLatestScheduledProgress() async throws {
    let saver = RecordingProgressSaver(results: [.saved])
    let coordinator = WebDAVReaderProgressUploadCoordinator(
      saver: saver,
      debounceNanoseconds: 60_000_000_000
    )

    await coordinator.schedule(
      configuration: try configuration(),
      book: book(),
      progress: progress(chapter: 0, position: 10, time: 100)
    )
    await coordinator.schedule(
      configuration: try configuration(),
      book: book(),
      progress: progress(chapter: 1, position: 20, time: 200)
    )
    await coordinator.schedule(
      configuration: try configuration(),
      book: book(),
      progress: progress(chapter: 2, position: 30, time: 300)
    )

    let result = await coordinator.flush()
    XCTAssertEqual(.saved, result)
    let documents = await saver.capturedDocuments()
    XCTAssertEqual(1, documents.count)
    XCTAssertEqual(2, documents.first?.durChapterIndex)
    XCTAssertEqual(30, documents.first?.durChapterPos)
    XCTAssertEqual(300, documents.first?.durChapterTime)
  }

  func testSuccessfulDuplicateIsNotUploadedAgain() async throws {
    let saver = RecordingProgressSaver(results: [.saved])
    let coordinator = WebDAVReaderProgressUploadCoordinator(
      saver: saver,
      debounceNanoseconds: 60_000_000_000
    )
    let value = progress(chapter: 1, position: 20, time: 200)

    await coordinator.schedule(
      configuration: try configuration(),
      book: book(),
      progress: value
    )
    let firstResult = await coordinator.flush()
    XCTAssertEqual(.saved, firstResult)
    await coordinator.schedule(
      configuration: try configuration(),
      book: book(),
      progress: value
    )

    let duplicateResult = await coordinator.flush()
    let documents = await saver.capturedDocuments()
    XCTAssertNil(duplicateResult)
    XCTAssertEqual(1, documents.count)
  }

  func testFailedUploadCanRetryWithoutBlockingLaterProgress() async throws {
    let saver = RecordingProgressSaver(
      results: [.failed(.transportUnavailable), .saved]
    )
    let coordinator = WebDAVReaderProgressUploadCoordinator(
      saver: saver,
      debounceNanoseconds: 60_000_000_000
    )
    let configuration = try configuration()
    let value = progress(chapter: 1, position: 20, time: 200)

    await coordinator.schedule(
      configuration: configuration,
      book: book(),
      progress: value
    )
    let failedResult = await coordinator.flush()
    let recordedFailure = await coordinator.lastResult
    XCTAssertEqual(.failed(.transportUnavailable), failedResult)
    XCTAssertEqual(.failed(.transportUnavailable), recordedFailure)

    await coordinator.schedule(
      configuration: configuration,
      book: book(),
      progress: value
    )
    let retryResult = await coordinator.flush()
    let documents = await saver.capturedDocuments()
    XCTAssertEqual(.saved, retryResult)
    XCTAssertEqual(2, documents.count)
  }

  private func configuration() throws -> WebDAVConnectionConfiguration {
    WebDAVConnectionConfiguration(
      serverURL: try XCTUnwrap(
        WebDAVServerURL(rawValue: "https://dav.example.test/dav")
      ),
      directoryName: "legado",
      credentialReference: WebDAVCredentialReference("credential")
    )
  }

  private func book() -> ShelfBookItem {
    ShelfBookItem(
      id: BookID(rawValue: "book"),
      candidate: ShelfBookCandidate(
        name: "SyncBook",
        author: "SyncAuthor",
        kind: "web",
        lastChapter: "第三章",
        intro: "",
        bookURL: "book://sync",
        coverURL: nil,
        originName: "source"
      ),
      membership: .member(groupID: 0),
      order: 0,
      chapterCount: 3,
      progress: nil
    )
  }

  private func progress(
    chapter: Int,
    position: Int,
    time: Int64
  ) -> ReadingProgress {
    ReadingProgress(
      position: ReadingPosition(
        chapterIndex: chapter,
        characterOffset: position
      ),
      chapterTitle: "第\(chapter + 1)章",
      updatedAtMilliseconds: time
    )
  }
}

private actor RecordingProgressSaver: WebDAVBookProgressSaving {
  private var results: [WebDAVBookProgressSaveResult]
  private var documents: [WebDAVBookProgressDocument] = []

  init(results: [WebDAVBookProgressSaveResult]) {
    self.results = results
  }

  func save(
    configuration: WebDAVConnectionConfiguration,
    document: WebDAVBookProgressDocument
  ) async -> WebDAVBookProgressSaveResult {
    documents.append(document)
    guard !results.isEmpty else { return .saved }
    return results.removeFirst()
  }

  func capturedDocuments() -> [WebDAVBookProgressDocument] {
    documents
  }
}
