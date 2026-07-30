import ScriptJavaScriptCore
import SourceRuntime
import XCTest

final class JavaScriptCoreResponseBridgeTests: XCTestCase {
  func testFrozenAndroidStrResponseTransformScript() async throws {
    let runtime = JavaScriptCoreSourceScriptRuntime()
    let response = SourceScriptResponse(
      url: try HTTPURL("https://reader.example/search"),
      body: "<li class=\"locked-item\">locked</li>"
    )
    let script = """
      new Packages.io.legado.app.help.http.StrResponse(
        result.url(),
        String(result.body()).replace("locked-item", "book-item")
      )
      """

    let transformed = try await SourceScriptResponseEvaluator(
      runtime: runtime,
      sessionID: .init(rawValue: "source-1")
    ).evaluate(script: script, response: response)

    XCTAssertEqual(response.url, transformed.url)
    XCTAssertEqual(
      "<li class=\"book-item\">locked</li>",
      transformed.body
    )
  }

  func testReturningOriginalResponsePreservesURLAndBody() async throws {
    let runtime = JavaScriptCoreSourceScriptRuntime()
    let response = SourceScriptResponse(
      url: try HTTPURL("https://reader.example/original"),
      body: "original"
    )

    let transformed = try await SourceScriptResponseEvaluator(
      runtime: runtime,
      sessionID: .init(rawValue: "source-1")
    ).evaluate(script: "result", response: response)

    XCTAssertEqual(response, transformed)
  }

  func testResponsePackagesDoNotExposeArbitraryJavaObjects() async throws {
    let runtime = JavaScriptCoreSourceScriptRuntime()
    let response = SourceScriptResponse(
      url: try HTTPURL("https://reader.example/original"),
      body: "original"
    )

    do {
      _ = try await SourceScriptResponseEvaluator(
        runtime: runtime,
        sessionID: .init(rawValue: "source-1")
      ).evaluate(
        script: "Packages.java.lang.Runtime.getRuntime(); result",
        response: response
      )
      XCTFail("Expected arbitrary Packages access to fail")
    } catch let issue as SourceScriptIssue {
      XCTAssertEqual(.executionFailed, issue.code)
    }
  }

  func testResponsePackagesDoNotLeakIntoRuleEvaluation() async throws {
    let runtime = JavaScriptCoreSourceScriptRuntime()
    let response = SourceScriptResponse(
      url: try HTTPURL("https://reader.example/original"),
      body: "original"
    )
    _ = try await SourceScriptResponseEvaluator(
      runtime: runtime,
      sessionID: .init(rawValue: "source-1")
    ).evaluate(script: "result", response: response)

    let value = try await runtime.evaluate(
      SourceScriptRequest(
        sessionID: .init(rawValue: "source-1"),
        script: "typeof Packages"
      ),
      host: nil
    )

    XCTAssertEqual(.string("undefined"), value)
  }
}
