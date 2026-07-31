import SourceRuntime
import XCTest

final class SourceImageDecodeTests: XCTestCase {
  func testBlankRuleKeepsOriginalBytesWithoutCallingRuntime() async {
    let runtime = RecordingRuntime(output: .array([]))
    let result = await decoder(runtime).decode(
      bytes: [1, 2, 3],
      rule: " \n ",
      context: .init(sourceURL: "https://reader.example/image")
    )

    XCTAssertEqual(result, .passthrough([1, 2, 3]))
    let request = await runtime.request
    XCTAssertNil(request)
  }

  func testRuleReceivesBytesAndSourceURLThenReturnsDecodedBytes() async {
    let runtime = RecordingRuntime(output: .array([.number(8), .number(9)]))
    let result = await decoder(runtime).decode(
      bytes: [1, 2],
      rule: "decode(result)",
      context: .init(
        sourceURL: "https://reader.example/image",
        bindings: ["book": .string("book-token")]
      )
    )

    XCTAssertEqual(result, .decoded([8, 9]))
    let request = await runtime.request
    XCTAssertEqual(request?.purpose, .imageDecode)
    XCTAssertEqual(request?.result, .array([.number(1), .number(2)]))
    XCTAssertEqual(request?.baseURL, "https://reader.example/image")
    XCTAssertEqual(request?.bindings["src"], .string("https://reader.example/image"))
    XCTAssertEqual(request?.bindings["book"], .string("book-token"))
  }

  func testScriptFailureAndInvalidResultDoNotReturnCipherBytes() async {
    let failed = await decoder(
      RecordingRuntime(issue: .executionFailed)
    ).decode(
      bytes: [1, 2],
      rule: "throw Error()",
      context: .init(sourceURL: "https://reader.example/image")
    )
    let invalid = await decoder(
      RecordingRuntime(output: .array([.number(256)]))
    ).decode(
      bytes: [1, 2],
      rule: "result",
      context: .init(sourceURL: "https://reader.example/image")
    )

    XCTAssertEqual(failed, .failed(.executionFailed))
    XCTAssertEqual(invalid, .failed(.invalidResult))
  }

  private func decoder(_ runtime: some SourceScriptRuntime) -> SourceImageDecoder {
    SourceImageDecoder(runtime: runtime, sessionID: .init(rawValue: "image-source"))
  }
}

private actor RecordingRuntime: SourceScriptRuntime {
  private(set) var request: SourceScriptRequest?
  private let output: SourceScriptValue?
  private let issue: SourceScriptIssueCode?

  init(
    output: SourceScriptValue? = nil,
    issue: SourceScriptIssueCode? = nil
  ) {
    self.output = output
    self.issue = issue
  }

  func evaluate(
    _ request: SourceScriptRequest,
    host: (any SourceScriptHosting)?
  ) async throws -> SourceScriptValue {
    self.request = request
    if let issue { throw SourceScriptIssue(code: issue) }
    return output ?? .undefined
  }
}
