import LibraryDomain
import XCTest

final class ShelfBatchExecutionTests: XCTestCase {
  func testFailureAndSkipDoNotRollbackOrStopFollowingBooks() async {
    let ids = ["first", "search-fail", "local", "last"].map {
      BookID(rawValue: $0)
    }

    let report = await ShelfBatchExecution.run(bookIDs: ids) { id in
      switch id.rawValue {
      case "search-fail":
        .failed(.searchFailed)
      case "local":
        .skipped(.localBook)
      default:
        .committed
      }
    }

    XCTAssertEqual(
      report.results.map(\.status),
      [
        .committed,
        .failed(.searchFailed),
        .skipped(.localBook),
        .committed,
      ]
    )
    XCTAssertEqual(
      report.committedBookIDs.map(\.rawValue),
      ["first", "last"]
    )
    XCTAssertEqual(
      report.failedBookIDs.map(\.rawValue),
      ["search-fail"]
    )
    XCTAssertTrue(report.isPartialCommit)
  }

  func testCancellationKeepsCommittedPrefixAndCancelsRemainder() async {
    let ids = ["committed", "cancel", "remaining"].map {
      BookID(rawValue: $0)
    }

    let report = await ShelfBatchExecution.run(bookIDs: ids) { id in
      if id.rawValue == "cancel" {
        throw CancellationError()
      }
      return .committed
    }

    XCTAssertEqual(
      report.results.map(\.status),
      [.committed, .cancelled, .cancelled]
    )
    XCTAssertEqual(
      report.committedBookIDs.map(\.rawValue),
      ["committed"]
    )
    XCTAssertEqual(
      report.cancelledBookIDs.map(\.rawValue),
      ["cancel", "remaining"]
    )
    XCTAssertTrue(report.isPartialCommit)
  }

  func testUnexpectedFailureIsRecordedAndProcessingContinues() async {
    let ids = ["throw", "after"].map(BookID.init(rawValue:))

    let report = await ShelfBatchExecution.run(bookIDs: ids) { id in
      if id.rawValue == "throw" {
        throw TestFailure()
      }
      return .committed
    }

    XCTAssertEqual(
      report.results.map(\.status),
      [.failed(.operationFailed), .committed]
    )
    XCTAssertEqual(
      report.committedBookIDs.map(\.rawValue),
      ["after"]
    )
  }
}

private struct TestFailure: Error {}
