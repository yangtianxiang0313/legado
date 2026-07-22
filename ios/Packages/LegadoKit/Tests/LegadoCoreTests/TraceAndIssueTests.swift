import XCTest

@testable import LegadoCore

final class TraceAndIssueTests: XCTestCase {
  func testTraceRecorderProducesStableMonotonicEventsAndSnapshots() async {
    let recorder = TraceRecorder(id: TraceID(rawValue: "trace-1"))
    await recorder.entered(.requestBuild)
    await recorder.completed(.requestBuild)
    let first = await recorder.snapshot()
    await recorder.failed(.transport, code: .transportFailed)
    let second = await recorder.snapshot()

    XCTAssertEqual(first.events.map(\.sequence), [0, 1])
    XCTAssertEqual(second.events.map(\.sequence), [0, 1, 2])
    XCTAssertEqual(second.events.last?.issueCode, .transportFailed)
    XCTAssertEqual(first.events.count, 2)
  }

  func testSourceStageCodesAreUniqueAndStable() {
    XCTAssertEqual(SourceStage.requestBuild.rawValue, "request_build")
    XCTAssertEqual(SourceStage.transport.rawValue, "transport")
    XCTAssertEqual(SourceStage.responseDecode.rawValue, "response_decode")
    XCTAssertEqual(Set(SourceStage.allCases.map(\.rawValue)).count, SourceStage.allCases.count)
  }

  func testAppIssueIsStableCodableData() throws {
    let issue = AppIssue(
      code: .decodingFailed,
      stage: .responseDecode,
      sourceID: SourceID(rawValue: "source-1"),
      traceID: TraceID(rawValue: "trace-1"),
      retryable: false,
      recovery: .editSource
    )

    let data = try JSONEncoder().encode(issue)
    XCTAssertEqual(try JSONDecoder().decode(AppIssue.self, from: data), issue)
    let json = String(decoding: data, as: UTF8.self)
    XCTAssertFalse(json.contains("message"))
    XCTAssertFalse(json.contains("underlying"))
    XCTAssertFalse(json.contains("stack"))
  }

  func testCancellationErrorIsNotWrapped() async {
    do {
      _ =
        try await withAppIssueBoundary(
          operation: { throw CancellationError() },
          map: { _ in
            XCTFail("Cancellation must not be mapped")
            return fallbackIssue
          }
        ) as Void
      XCTFail("Expected cancellation")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
  }

  func testExistingAppIssueIsNotRewritten() async {
    let original = fallbackIssue
    do {
      _ =
        try await withAppIssueBoundary(
          operation: { throw original },
          map: { _ in
            XCTFail("Existing AppIssue must not be mapped")
            return fallbackIssue
          }
        ) as Void
      XCTFail("Expected AppIssue")
    } catch {
      XCTAssertEqual(error as? AppIssue, original)
    }
  }
}

private let fallbackIssue = AppIssue(
  code: .internalFailure,
  stage: nil,
  sourceID: nil,
  traceID: TraceID(rawValue: "trace-fallback"),
  retryable: false,
  recovery: .none
)
