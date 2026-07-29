import Foundation
import XCTest

@testable import SourceRuntime

final class SourceRateLimiterTests: XCTestCase {
  func testZeroDisablesRateLimit() async {
    let limiter = SourceRateLimiter(clock: TestRateLimitClock(1_000))

    let result = await limiter.start(
      sourceKey: "source",
      concurrentRate: "0"
    )

    XCTAssertFalse(result.isActive)
    XCTAssertTrue(result.isAllowed)
    XCTAssertNil(result.state)
    XCTAssertNil(result.permit)
  }

  func testMinimumIntervalRemainsActiveAfterFetchEnd() async {
    let clock = TestRateLimitClock(1_000)
    let limiter = SourceRateLimiter(clock: clock)

    let first = await limiter.start(
      sourceKey: "source",
      concurrentRate: "60000"
    )
    let second = await limiter.start(
      sourceKey: "source",
      concurrentRate: "60000"
    )
    await limiter.finish(first.permit)
    let afterEnd = await limiter.start(
      sourceKey: "source",
      concurrentRate: "60000"
    )

    XCTAssertTrue(first.isAllowed)
    XCTAssertFalse(second.isAllowed)
    XCTAssertEqual(second.waitMilliseconds, 60_000)
    XCTAssertEqual(second.state?.frequency, 1)
    XCTAssertFalse(afterEnd.isAllowed)
    XCTAssertEqual(afterEnd.waitMilliseconds, 60_000)

    clock.advance(by: 60_000)
    let afterWindow = await limiter.start(
      sourceKey: "source",
      concurrentRate: "60000"
    )
    XCTAssertTrue(afterWindow.isAllowed)
    XCTAssertEqual(afterWindow.state?.frequency, 1)
  }

  func testCountWindowAllowsConfiguredCountPlusInitialRecord() async {
    let limiter = SourceRateLimiter(clock: TestRateLimitClock(1_000))
    var results: [SourceRateLimitStartResult] = []

    for _ in 0..<4 {
      results.append(
        await limiter.start(
          sourceKey: "source",
          concurrentRate: "2/60000"
        )
      )
    }

    XCTAssertEqual(results.filter(\.isAllowed).count, 3)
    XCTAssertFalse(results[3].isAllowed)
    XCTAssertEqual(results[3].waitMilliseconds, 60_000)
    XCTAssertEqual(results[3].state?.frequency, 3)
  }

  func testDistinctKeysAreIsolated() async {
    let limiter = SourceRateLimiter(clock: TestRateLimitClock(1_000))

    let first = await limiter.start(
      sourceKey: "source-a",
      concurrentRate: "60000"
    )
    let second = await limiter.start(
      sourceKey: "source-b",
      concurrentRate: "60000"
    )

    XCTAssertTrue(first.isAllowed)
    XCTAssertTrue(second.isAllowed)
    XCTAssertNotEqual(first.state?.sourceKey, second.state?.sourceKey)
  }

  func testInvalidConfigurationsDegradeToAllowedWithoutMutation() async {
    let limiter = SourceRateLimiter(clock: TestRateLimitClock(1_000))

    let invalidIntervalFirst = await limiter.start(
      sourceKey: "interval",
      concurrentRate: "invalid"
    )
    let invalidIntervalSecond = await limiter.start(
      sourceKey: "interval",
      concurrentRate: "invalid"
    )
    let invalidWindowFirst = await limiter.start(
      sourceKey: "window",
      concurrentRate: "2/invalid"
    )
    let invalidWindowSecond = await limiter.start(
      sourceKey: "window",
      concurrentRate: "2/invalid"
    )

    XCTAssertTrue(invalidIntervalFirst.isAllowed)
    XCTAssertTrue(invalidIntervalSecond.isAllowed)
    XCTAssertEqual(invalidIntervalSecond.state?.mode, .minimumInterval)
    XCTAssertEqual(invalidIntervalSecond.state?.frequency, 1)
    XCTAssertTrue(invalidWindowFirst.isAllowed)
    XCTAssertTrue(invalidWindowSecond.isAllowed)
    XCTAssertEqual(invalidWindowSecond.state?.mode, .countPerWindow)
    XCTAssertEqual(invalidWindowSecond.state?.frequency, 1)
  }

  func testActorSerializesConcurrentCountWindowStarts() async {
    let limiter = SourceRateLimiter(clock: TestRateLimitClock(1_000))

    let allowed = await withTaskGroup(
      of: Bool.self,
      returning: Int.self
    ) { group in
      for _ in 0..<12 {
        group.addTask {
          await limiter.start(
            sourceKey: "source",
            concurrentRate: "2/60000"
          ).isAllowed
        }
      }
      var count = 0
      for await value in group where value {
        count += 1
      }
      return count
    }

    XCTAssertEqual(allowed, 3)
  }
}

private final class TestRateLimitClock:
  SourceRateLimitClock,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var milliseconds: Int64

  init(_ milliseconds: Int64) {
    self.milliseconds = milliseconds
  }

  func nowMilliseconds() -> Int64 {
    lock.withLock { milliseconds }
  }

  func advance(by delta: Int64) {
    lock.withLock {
      milliseconds += delta
    }
  }
}
