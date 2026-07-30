import XCTest
@testable import SourceRuntime

final class SourceScriptRuntimeContractTests: XCTestCase {
  func testRequestPreservesScriptContextWithoutPlatformTypes() {
    let request = SourceScriptRequest(
      sessionID: SourceScriptSessionID(rawValue: "source-session-1"),
      script: "result.toString() + baseUrl",
      result: .string("chapter"),
      baseURL: "https://reader.example/book/",
      bindings: [
        "bookName": .string("银河"),
        "page": .number(2),
      ]
    )

    XCTAssertEqual("source-session-1", request.sessionID.rawValue)
    XCTAssertEqual(.string("chapter"), request.result)
    XCTAssertEqual(
      "https://reader.example/book/",
      request.baseURL
    )
    XCTAssertEqual(.number(2), request.bindings["page"])
  }

  func testUnavailableRuntimeReturnsStableRedactedIssue() async {
    let request = SourceScriptRequest(
      sessionID: SourceScriptSessionID(rawValue: "source-session-1"),
      script: "secret script body"
    )

    do {
      _ = try await SourceScriptUnavailableRuntime().evaluate(
        request,
        host: nil
      )
      XCTFail("Expected capability denial")
    } catch let issue as SourceScriptIssue {
      XCTAssertEqual(.capabilityDenied, issue.code)
      XCTAssertFalse(String(describing: issue).contains(request.script))
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testVariableHostUsesExistingAndroidScopeOrder() async throws {
    let source = SourceVariableStore(values: ["token": "source"])
    let book = SourceVariableStore(values: ["token": "book"])
    let chapter = SourceVariableStore()
    let host = SourceVariableScriptHost(
      resolver: SourceVariableResolver(
        role: .rule,
        scopes: SourceVariableScopes(
          chapter: chapter,
          book: book,
          source: source
        )
      )
    )
    let sessionID = SourceScriptSessionID(rawValue: "source-session-1")

    let inherited = try await host.execute(
      .getVariable(name: "token"),
      sessionID: sessionID
    )
    let written = try await host.execute(
      .putVariable(name: "token", value: "chapter"),
      sessionID: sessionID
    )
    let resolved = try await host.execute(
      .getVariable(name: "token"),
      sessionID: sessionID
    )
    let chapterToken = await chapter.get("token")
    let bookToken = await book.get("token")

    XCTAssertEqual(.string("book"), inherited)
    XCTAssertEqual(.string("chapter"), written)
    XCTAssertEqual(.string("chapter"), resolved)
    XCTAssertEqual("chapter", chapterToken)
    XCTAssertEqual("book", bookToken)
  }
}
