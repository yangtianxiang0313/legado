import XCTest
@testable import SourceRuntime

final class SourceScriptLibraryContractTests: XCTestCase {
  func testRequestCarriesOpaqueInlineLibraryWithoutInterpretingIt() {
    let source = """
      function sourceName(value) {
        return "《" + value + "》";
      }
      """
    let request = SourceScriptRequest(
      sessionID: .init(rawValue: "source-1"),
      library: SourceScriptLibrary(source: source),
      script: "sourceName(result)"
    )

    XCTAssertEqual(.inline, request.library?.kind)
    XCTAssertEqual(source, request.library?.source)
    XCTAssertEqual("sourceName(result)", request.script)
  }

  func testLibraryIsOptionalForOrdinaryScriptRequests() {
    let request = SourceScriptRequest(
      sessionID: .init(rawValue: "source-1"),
      script: "result"
    )

    XCTAssertNil(request.library)
  }

  func testLibrarySourceRemainsDistinctFromExecutableRequestScript() {
    let request = SourceScriptRequest(
      sessionID: .init(rawValue: "source-1"),
      purpose: .responseCheck,
      library: SourceScriptLibrary(
        source: "function unlock(value) { return value; }"
      ),
      script: "unlock(result)"
    )

    XCTAssertEqual(.responseCheck, request.purpose)
    XCTAssertEqual(
      "function unlock(value) { return value; }",
      request.library?.source
    )
    XCTAssertEqual("unlock(result)", request.script)
  }
}
