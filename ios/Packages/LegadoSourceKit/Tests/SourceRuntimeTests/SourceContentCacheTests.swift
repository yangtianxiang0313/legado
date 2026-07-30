import Foundation
import SourceRuntime
import XCTest

final class SourceContentCacheTests: XCTestCase {
  func testTextLifecycleUsesAndroidFileIdentityAndContentBoundaries()
    async throws
  {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = SourceContentCache(root: root)
    let book = SourceCacheBook(
      url: "http://books.test/text-lifecycle",
      name: "Text Lifecycle"
    )
    let chapter = SourceCacheChapter(
      url: "/text/chapter-2",
      title: "Chapter Two",
      index: 0
    )

    XCTAssertEqual(
      SourceContentCache.chapterFileName(
        index: chapter.index,
        title: chapter.title
      ),
      "00000-1b5d9071aba449b0.nb"
    )
    let before = await cache.hasContent(book: book, chapter: chapter)
    XCTAssertFalse(before)
    try await cache.saveText("", book: book, chapter: chapter)
    let afterEmpty = await cache.hasContent(book: book, chapter: chapter)
    XCTAssertFalse(afterEmpty)

    try await cache.saveText(
      "line-one\nline-two",
      book: book,
      chapter: chapter
    )
    let afterText = await cache.hasContent(book: book, chapter: chapter)
    XCTAssertTrue(afterText)
    let stored = try await cache.text(book: book, chapter: chapter)
    let files = try await cache.chapterFiles(book: book)
    XCTAssertEqual(stored, "line-one\nline-two")
    XCTAssertEqual(files, ["00000-1b5d9071aba449b0.nb"])

    try await cache.deleteText(book: book, chapter: chapter)
    let afterDelete = await cache.hasContent(book: book, chapter: chapter)
    XCTAssertFalse(afterDelete)
    let volume = SourceCacheChapter(
      url: "Volume One::marker",
      title: "Volume One",
      index: 1,
      isVolume: true
    )
    let volumePresent = await cache.hasContent(book: book, chapter: volume)
    XCTAssertTrue(volumePresent)
  }

  func testImageCompletionSeparatesTextMissingInvalidAndSVG()
    async throws
  {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = SourceContentCache(root: root)
    let book = SourceCacheBook(
      url: "http://books.test/images",
      name: "Images"
    )
    let chapter = SourceCacheChapter(
      url: "/chapter",
      title: "Images",
      index: 3
    )
    let missing = "http://assets.test/missing.jpg"
    let valid = "http://assets.test/valid.svg"

    let withoutText = try await cache.hasImageContent(
      book: book,
      chapter: chapter
    )
    XCTAssertFalse(withoutText)
    try await cache.saveText(
      "plain cached text",
      book: book,
      chapter: chapter
    )
    let plainText = try await cache.hasImageContent(
      book: book,
      chapter: chapter
    )
    XCTAssertTrue(plainText)

    try await cache.saveText(
      "<img src=\"\(missing)\">",
      book: book,
      chapter: chapter
    )
    let missingImage = try await cache.hasImageContent(
      book: book,
      chapter: chapter
    )
    XCTAssertFalse(missingImage)
    try await cache.writeImage(
      Data("not-an-image".utf8),
      sourceURL: missing,
      book: book
    )
    let invalidImage = try await cache.hasImageContent(
      book: book,
      chapter: chapter
    )
    let invalidExists = await cache.imageExists(
      sourceURL: missing,
      book: book
    )
    XCTAssertFalse(invalidImage)
    XCTAssertFalse(invalidExists)

    try await cache.saveText(
      "<img src='\(valid)'>",
      book: book,
      chapter: chapter
    )
    try await cache.writeImage(
      Data(
        """
        <svg xmlns="http://www.w3.org/2000/svg" width="10" height="20"/>
        """.utf8
      ),
      sourceURL: valid,
      book: book
    )
    let validImage = try await cache.hasImageContent(
      book: book,
      chapter: chapter
    )
    let validExists = await cache.imageExists(
      sourceURL: valid,
      book: book
    )
    XCTAssertTrue(validImage)
    XCTAssertTrue(validExists)
  }

  func testQueueDeduplicatesRangesStopsAndResumes() async {
    let model = SourceCacheQueueModel(bookURL: "book")
    await model.addDownload(2...4)
    await model.addDownload(3...5)
    let before = await model.snapshot()
    XCTAssertEqual(before.waitingIndices, [2, 3, 4, 5])
    XCTAssertTrue(before.isRunning)

    await model.stop()
    let stopped = await model.snapshot()
    XCTAssertEqual(stopped.waitingIndices, [])
    XCTAssertTrue(stopped.isStopped)

    await model.addDownload(6...6)
    let resumed = await model.snapshot()
    XCTAssertEqual(resumed.waitingIndices, [6])
    XCTAssertTrue(resumed.isRunning)
  }

  func testRetryBudgetConcurrentFailureAndStoppedFailure() async {
    let ordinary = SourceCacheQueueModel(bookURL: "ordinary")
    await ordinary.addDownload(7...7)
    var transitions: [SourceCacheFailureTransition] = []
    for _ in 1...3 {
      await ordinary.beginAttempt(7)
      transitions.append(
        await ordinary.recordFailure(
          index: 7,
          key: "ordinary/chapter",
          kind: .ordinary
        )
      )
    }
    XCTAssertEqual(transitions.map(\.errorCount), [1, 2, 3])
    XCTAssertEqual(transitions.map(\.requeued), [true, true, false])
    let ordinaryStopped = (await ordinary.snapshot()).isStopped
    XCTAssertTrue(ordinaryStopped)

    let concurrent = SourceCacheQueueModel(bookURL: "concurrent")
    await concurrent.addDownload(8...8)
    await concurrent.beginAttempt(8)
    let concurrentTransition = await concurrent.recordFailure(
      index: 8,
      key: "concurrent/chapter",
      kind: .concurrent
    )
    XCTAssertEqual(concurrentTransition.errorCount, 0)
    XCTAssertTrue(concurrentTransition.requeued)

    let stopped = SourceCacheQueueModel(bookURL: "stopped")
    await stopped.addDownload(9...9)
    await stopped.beginAttempt(9)
    _ = await stopped.beginFailure(
      index: 9,
      key: "stopped/chapter",
      kind: .ordinary
    )
    await stopped.stop()
    let requeued = await stopped.finishFailure(
      index: 9,
      key: "stopped/chapter",
      kind: .ordinary
    )
    XCTAssertFalse(requeued)
    let stoppedErrorCount = await stopped.errorCount(
      for: "stopped/chapter"
    )
    let stoppedState = (await stopped.snapshot()).isStopped
    XCTAssertEqual(stoppedErrorCount, 1)
    XCTAssertTrue(stoppedState)
  }

  func testSuccessCancelAndRegistryCleanupUseExplicitState() async {
    let success = SourceCacheQueueModel(bookURL: "success")
    await success.addDownload(10...10)
    await success.beginAttempt(10)
    await success.setErrorCount(2, for: "success/chapter")
    await success.completeSuccess(index: 10, key: "success/chapter")
    let successRecorded = await success.containsSuccess("success/chapter")
    let successErrorCount = await success.errorCount(
      for: "success/chapter"
    )
    let successDownloading = await success.containsDownloading(10)
    XCTAssertTrue(successRecorded)
    XCTAssertEqual(successErrorCount, 0)
    XCTAssertFalse(successDownloading)

    let cancel = SourceCacheQueueModel(bookURL: "cancel")
    await cancel.addDownload(11...11)
    await cancel.beginAttempt(11)
    await cancel.cancel(index: 11)
    let cancelRequeued = await cancel.containsWaiting(11)
    XCTAssertTrue(cancelRequeued)
    await cancel.beginAttempt(11)
    await cancel.stop()
    await cancel.cancel(index: 11)
    let stoppedCancelRequeued = await cancel.containsWaiting(11)
    XCTAssertFalse(stoppedCancelRequeued)

    let registry = SourceCacheQueueRegistry()
    let registered = await registry.model(for: "registry")
    await registered.addDownload(13...13)
    await registry.finish("registry")
    let retained = await registry.contains("registry")
    XCTAssertTrue(retained)
    await registered.prepareWaitingRetryWithoutQueuedWork()
    let retryIsStopped = (await registered.snapshot()).isStopped
    XCTAssertFalse(retryIsStopped)
    await registry.finish("registry")
    let removed = await registry.contains("registry")
    XCTAssertFalse(removed)
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
  }
}
