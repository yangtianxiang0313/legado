import Foundation
import LegadoCore
import XCTest

@testable import SourceRuntime

final class HTTPTransportTests: XCTestCase {
  func testNonSuccessfulStatusIsStillAResponseAndTraceCompletes() async throws {
    let expected = try HTTPResponse(
      statusCode: 404,
      effectiveURL: HTTPURL("https://example.test/final"),
      body: HTTPBody(Data("missing".utf8))
    )
    let boundary = HTTPTransportBoundary(
      transport: ClosureHTTPTransport { _ in expected }
    )
    let trace = TraceRecorder(id: TraceID(rawValue: "trace-404"))

    let response = try await boundary.execute(
      HTTPRequest(method: .get, url: HTTPURL("https://example.test/start")),
      sourceID: SourceID(rawValue: "source-1"),
      trace: trace
    )

    XCTAssertEqual(response, expected)
    let events = await trace.snapshot().events
    XCTAssertEqual(
      events,
      [
        TraceEvent(sequence: 0, stage: .transport, kind: .entered),
        TraceEvent(sequence: 1, stage: .transport, kind: .completed),
      ]
    )
  }

  func testCancellationErrorIsPreservedAndTracedAsCancellation() async throws {
    let boundary = HTTPTransportBoundary(
      transport: ClosureHTTPTransport { _ in throw CancellationError() }
    )
    let trace = TraceRecorder(id: TraceID(rawValue: "trace-cancel"))

    do {
      _ = try await boundary.execute(
        HTTPRequest(method: .get, url: HTTPURL("https://example.test")),
        sourceID: nil,
        trace: trace
      )
      XCTFail("Expected cancellation")
    } catch is CancellationError {
      let lastEvent = await trace.snapshot().events.last
      XCTAssertEqual(
        lastEvent,
        TraceEvent(sequence: 1, stage: .transport, kind: .cancelled)
      )
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testStableFailuresMapToSanitizedAppIssues() async throws {
    let expected: [(HTTPTransportFailure, IssueCode, Bool, Recovery)] = [
      (.invalidRequest, .transportFailed, false, .none),
      (.connectionFailed, .transportFailed, true, .retry),
      (.timeout, .timeout, true, .retry),
      (.invalidResponse, .transportFailed, false, .none),
      (.responseTooLarge, .responseTooLarge, false, .editSource),
    ]

    for (failure, code, retryable, recovery) in expected {
      let trace = TraceRecorder(id: TraceID(rawValue: "trace-\(failure.rawValue)"))
      let boundary = HTTPTransportBoundary(
        transport: ClosureHTTPTransport { _ in throw failure }
      )
      do {
        _ = try await boundary.execute(
          HTTPRequest(method: .get, url: HTTPURL("https://example.test")),
          sourceID: SourceID(rawValue: "source-1"),
          trace: trace
        )
        XCTFail("Expected \(failure)")
      } catch let issue as AppIssue {
        XCTAssertEqual(issue.code, code)
        XCTAssertEqual(issue.stage, .transport)
        XCTAssertEqual(issue.retryable, retryable)
        XCTAssertEqual(issue.recovery, recovery)
      }
    }
  }

  func testUnknownFailureDoesNotLeakUnderlyingSecret() async throws {
    let secret = "authorization=token&body=private"
    let trace = TraceRecorder(id: TraceID(rawValue: "trace-secret"))
    let boundary = HTTPTransportBoundary(
      transport: ClosureHTTPTransport { _ in throw SensitiveFailure(description: secret) }
    )

    do {
      _ = try await boundary.execute(
        HTTPRequest(method: .post, url: HTTPURL("https://example.test")),
        sourceID: SourceID(rawValue: "source-secret"),
        trace: trace
      )
      XCTFail("Expected issue")
    } catch let issue as AppIssue {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let encoded = try encoder.encode(issue)
      XCTAssertEqual(issue.code, .transportFailed)
      XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(secret))
    }
  }
}

private struct ClosureHTTPTransport: HTTPTransport {
  let handler: @Sendable (HTTPRequest) async throws -> HTTPResponse

  func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
    try await handler(request)
  }
}

private struct SensitiveFailure: Error, CustomStringConvertible, Sendable {
  let description: String
}
