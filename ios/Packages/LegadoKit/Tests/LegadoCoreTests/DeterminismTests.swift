import Foundation
import XCTest

@testable import LegadoCore

final class DeterminismTests: XCTestCase {
  func testClockAndIDGeneratorSupportDeterministicFakes() {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let clock = FixedClock(now: date)
    let traceID = TraceID(rawValue: "fixed-trace")
    let generator = FixedIDGenerator(value: traceID)

    XCTAssertEqual(clock.now, date)
    XCTAssertEqual(clock.now, date)
    XCTAssertEqual(generator.makeTraceID(), traceID)
  }
}

private struct FixedClock: LegadoCore.Clock {
  let now: Date
}

private struct FixedIDGenerator: IDGenerating {
  let value: TraceID

  func makeTraceID() -> TraceID {
    value
  }
}
