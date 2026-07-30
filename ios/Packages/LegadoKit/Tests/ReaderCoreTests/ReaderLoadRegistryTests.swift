import ReaderCore
import XCTest

final class ReaderLoadRegistryTests: XCTestCase {
  func testSameIndexIsDeduplicatedUntilMatchingTokenFinishes() {
    var registry = ReaderLoadRegistry()
    let token = registry.acquire(chapterIndex: 4)

    XCTAssertNotNil(token)
    XCTAssertNil(registry.acquire(chapterIndex: 4))
    XCTAssertEqual(registry.activeChapterIndices, [4])
    XCTAssertTrue(registry.finish(token!))
    XCTAssertNotNil(registry.acquire(chapterIndex: 4))
  }

  func testDifferentAndNegativeIndicesRemainIndependent() {
    var registry = ReaderLoadRegistry()

    XCTAssertNotNil(registry.acquire(chapterIndex: -1))
    XCTAssertNotNil(registry.acquire(chapterIndex: 4))
    XCTAssertNotNil(registry.acquire(chapterIndex: 5))
    XCTAssertEqual(registry.activeChapterIndices, [-1, 4, 5])
  }

  func testOldSessionCompletionCannotEraseReplacement() {
    var registry = ReaderLoadRegistry()
    let old = registry.acquire(chapterIndex: 7)!
    registry.beginSession()
    let replacement = registry.acquire(chapterIndex: 7)!

    XCTAssertNotEqual(old.generation, replacement.generation)
    XCTAssertEqual(
      registry.admit(old, currentChapterIndex: 7),
      .rejectedStale
    )
    XCTAssertEqual(registry.activeToken(for: 7), replacement)
    XCTAssertNil(registry.acquire(chapterIndex: 7))
  }

  func testOnlyExactNonceCanFinishActiveLoad() {
    var registry = ReaderLoadRegistry()
    let token = registry.acquire(chapterIndex: 3)!
    let forged = ReaderLoadToken(
      generation: token.generation,
      chapterIndex: token.chapterIndex,
      nonce: token.nonce + 1
    )

    XCTAssertFalse(registry.finish(forged))
    XCTAssertEqual(registry.activeToken(for: 3), token)
    XCTAssertTrue(registry.finish(token))
  }

  func testAdmissionMapsWindowAndConsumesOutsideResult() {
    var registry = ReaderLoadRegistry()
    let previous = registry.acquire(chapterIndex: 3)!
    let current = registry.acquire(chapterIndex: 4)!
    let next = registry.acquire(chapterIndex: 5)!
    let outside = registry.acquire(chapterIndex: 8)!

    XCTAssertEqual(
      registry.admit(previous, currentChapterIndex: 4),
      .accepted(.previous)
    )
    XCTAssertEqual(
      registry.admit(current, currentChapterIndex: 4),
      .accepted(.current)
    )
    XCTAssertEqual(
      registry.admit(next, currentChapterIndex: 4),
      .accepted(.next)
    )
    XCTAssertEqual(
      registry.admit(outside, currentChapterIndex: 4),
      .rejectedOutsideWindow
    )
    XCTAssertTrue(registry.activeChapterIndices.isEmpty)
  }
}
