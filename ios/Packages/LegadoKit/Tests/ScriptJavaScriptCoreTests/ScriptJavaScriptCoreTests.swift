import XCTest
import ScriptJavaScriptCore
import SourceRuntime

final class ScriptJavaScriptCoreTests: XCTestCase {
  func testEvaluatesAndroidResultAndBaseURLBindings() async throws {
    let runtime = JavaScriptCoreSourceScriptRuntime()
    let value = try await runtime.evaluate(
      SourceScriptRequest(
        sessionID: .init(rawValue: "source-1"),
        script: "result.toString() + '|' + baseUrl + '|' + page",
        result: .string("Alpha"),
        baseURL: "https://reader.example/",
        bindings: ["page": .number(2)]
      ),
      host: nil
    )

    XCTAssertEqual(
      .string("Alpha|https://reader.example/|2"),
      value
    )
  }

  func testVariableGetAndPutUseClosedHostCommands() async throws {
    let variables = SourceVariableStore(values: ["token": "old"])
    let host = SourceVariableScriptHost(
      resolver: SourceVariableResolver(
        role: .rule,
        scopes: SourceVariableScopes(ruleData: variables)
      )
    )
    let runtime = JavaScriptCoreSourceScriptRuntime()
    let value = try await runtime.evaluate(
      SourceScriptRequest(
        sessionID: .init(rawValue: "source-1"),
        script: """
          java.put("token", java.get("token") + "-new");
          java.get("token");
          """
      ),
      host: host
    )
    let storedToken = await variables.get("token")

    XCTAssertEqual(.string("old-new"), value)
    XCTAssertEqual("old-new", storedToken)
  }

  func testWritesSurviveLaterScriptFailureLikeAndroid() async throws {
    let variables = SourceVariableStore()
    let host = SourceVariableScriptHost(
      resolver: SourceVariableResolver(
        role: .rule,
        scopes: SourceVariableScopes(ruleData: variables)
      )
    )
    let runtime = JavaScriptCoreSourceScriptRuntime()

    do {
      _ = try await runtime.evaluate(
        SourceScriptRequest(
          sessionID: .init(rawValue: "source-1"),
          script: "java.put('saved', 'yes'); throw new Error('secret')"
        ),
        host: host
      )
      XCTFail("Expected script failure")
    } catch let issue as SourceScriptIssue {
      XCTAssertEqual(.executionFailed, issue.code)
    }
    let saved = await variables.get("saved")
    XCTAssertEqual("yes", saved)
  }

  func testContextsAreIsolatedBySourceSession() async throws {
    let runtime = JavaScriptCoreSourceScriptRuntime()
    _ = try await runtime.evaluate(
      SourceScriptRequest(
        sessionID: .init(rawValue: "source-1"),
        script: "var sessionValue = 'one'; sessionValue"
      ),
      host: nil
    )
    let sameSession = try await runtime.evaluate(
      SourceScriptRequest(
        sessionID: .init(rawValue: "source-1"),
        script: "sessionValue",
      ),
      host: nil
    )
    let otherSession = try await runtime.evaluate(
      SourceScriptRequest(
        sessionID: .init(rawValue: "source-2"),
        script: "typeof sessionValue",
      ),
      host: nil
    )

    XCTAssertEqual(.string("one"), sameSession)
    XCTAssertEqual(.string("undefined"), otherSession)
  }
}
