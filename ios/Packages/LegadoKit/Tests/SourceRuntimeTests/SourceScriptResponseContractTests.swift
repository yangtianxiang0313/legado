import XCTest
@testable import SourceRuntime

final class SourceScriptResponseContractTests: XCTestCase {
  func testResponseCheckUsesStructuredURLAndBodyProjection() async throws {
    let runtime = RecordingResponseScriptRuntime(
      result: .object([
        "url": .string("https://reader.example/unlocked"),
        "body": .string("unlocked body"),
      ])
    )
    let original = SourceScriptResponse(
      url: try HTTPURL("https://reader.example/locked"),
      body: "locked body"
    )

    let transformed = try await SourceScriptResponseEvaluator(
      runtime: runtime,
      sessionID: .init(rawValue: "source-1")
    ).evaluate(
      script: "replaceResponse(result)",
      response: original
    )
    let recordedRequest = await runtime.lastRequest()
    let request = try XCTUnwrap(recordedRequest)

    XCTAssertEqual(.responseCheck, request.purpose)
    XCTAssertEqual(original.scriptValue, request.result)
    XCTAssertEqual("https://reader.example/locked", request.baseURL)
    XCTAssertEqual(
      try HTTPURL("https://reader.example/unlocked"),
      transformed.url
    )
    XCTAssertEqual("unlocked body", transformed.body)
  }

  func testEmptyResponseCheckPreservesResponseWithoutCallingRuntime()
    async throws
  {
    let runtime = RecordingResponseScriptRuntime(result: .undefined)
    let original = SourceScriptResponse(
      url: try HTTPURL("https://reader.example/original"),
      body: "original"
    )

    let result = try await SourceScriptResponseEvaluator(
      runtime: runtime,
      sessionID: .init(rawValue: "source-1")
    ).evaluate(script: "  ", response: original)

    XCTAssertEqual(original, result)
    let recordedRequest = await runtime.lastRequest()
    XCTAssertNil(recordedRequest)
  }

  func testResponseCheckRejectsNonResponseScriptResult() async throws {
    let runtime = RecordingResponseScriptRuntime(
      result: .string("not a response")
    )
    let original = SourceScriptResponse(
      url: try HTTPURL("https://reader.example/original"),
      body: "original"
    )

    do {
      _ = try await SourceScriptResponseEvaluator(
        runtime: runtime,
        sessionID: .init(rawValue: "source-1")
      ).evaluate(script: "badResult()", response: original)
      XCTFail("Expected invalid response result")
    } catch let issue as SourceScriptIssue {
      XCTAssertEqual(.invalidResult, issue.code)
    }
  }
}

private actor RecordingResponseScriptRuntime: SourceScriptRuntime {
  let result: SourceScriptValue
  private var request: SourceScriptRequest?

  init(result: SourceScriptValue) {
    self.result = result
  }

  func evaluate(
    _ request: SourceScriptRequest,
    host: (any SourceScriptHosting)?
  ) async throws -> SourceScriptValue {
    self.request = request
    return result
  }

  func lastRequest() -> SourceScriptRequest? {
    request
  }
}
