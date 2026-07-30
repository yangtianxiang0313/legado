import ReaderCore
import XCTest

final class ReaderContentAcquisitionTests: XCTestCase {
  func testCacheHitFinishesWithoutSourceDelegation() {
    let outcome = complete(
      ReaderContentAcquisitionContext(
        chapterExists: true,
        cachedContent: "缓存正文第一段\n缓存正文第二段",
        isLocalBook: false,
        localReadResult: nil,
        sourceAvailable: false
      )
    )

    XCTAssertEqual(outcome.initialContentState, .text)
    XCTAssertEqual(outcome.cachedContentAfterLoad, .text)
    XCTAssertEqual(
      outcome.contentAfterLoad,
      "缓存正文第一段\n缓存正文第二段"
    )
    XCTAssertFalse(outcome.sourceDelegated)
    XCTAssertTrue(outcome.loadingCleared)
  }

  func testEmptyCacheRemainsMissingWithoutSource() {
    let outcome = complete(
      ReaderContentAcquisitionContext(
        chapterExists: true,
        cachedContent: "",
        isLocalBook: false,
        localReadResult: nil,
        sourceAvailable: false
      )
    )

    XCTAssertEqual(outcome.initialContentState, .missing)
    XCTAssertEqual(outcome.cachedContentAfterLoad, .missing)
    XCTAssertNil(outcome.contentAfterLoad)
    XCTAssertTrue(outcome.chapterLoaded)
  }

  func testLocalFailureIsProjectedAsAndroidReaderContent() {
    let outcome = complete(
      ReaderContentAcquisitionContext(
        chapterExists: true,
        cachedContent: nil,
        isLocalBook: true,
        localReadResult: .failure(message: nil),
        sourceAvailable: false
      )
    )

    XCTAssertEqual(
      outcome.contentAfterLoad,
      "获取本地书籍内容失败\nnull"
    )
    XCTAssertEqual(outcome.cachedContentAfterLoad, .text)
    XCTAssertFalse(outcome.sourceDelegated)
  }

  func testRemoteMissDelegatesAndRecordsSourceFailure() {
    let context = ReaderContentAcquisitionContext(
      chapterExists: true,
      cachedContent: nil,
      isLocalBook: false,
      localReadResult: nil,
      sourceAvailable: true
    )
    let plan = AndroidReaderContentAcquisitionPolicy.plan(for: context)
    let outcome = AndroidReaderContentAcquisitionPolicy.complete(
      plan,
      sourceResult: .failure(message: "invalid_url")
    )

    XCTAssertEqual(plan.action, .loadSource)
    XCTAssertTrue(outcome.sourcePresent)
    XCTAssertTrue(outcome.sourceDelegated)
    XCTAssertEqual(outcome.downloadFailureCount, 1)
    XCTAssertFalse(outcome.downloadMarkedSuccess)
    XCTAssertTrue(outcome.loadingCleared)
  }

  func testMissingChapterClearsLoadingWithoutAcquisition() {
    let outcome = complete(
      ReaderContentAcquisitionContext(
        chapterExists: false,
        cachedContent: nil,
        isLocalBook: false,
        localReadResult: nil,
        sourceAvailable: false
      )
    )

    XCTAssertFalse(outcome.chapterLoaded)
    XCTAssertFalse(outcome.sourceDelegated)
    XCTAssertNil(outcome.contentAfterLoad)
    XCTAssertTrue(outcome.loadingCleared)
  }

  private func complete(
    _ context: ReaderContentAcquisitionContext
  ) -> ReaderContentAcquisitionOutcome {
    let plan = AndroidReaderContentAcquisitionPolicy.plan(for: context)
    return AndroidReaderContentAcquisitionPolicy.complete(plan)
  }
}
