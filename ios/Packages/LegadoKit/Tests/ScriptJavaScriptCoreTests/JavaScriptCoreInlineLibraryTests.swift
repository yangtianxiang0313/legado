import ScriptJavaScriptCore
import SourceRuntime
import XCTest

final class JavaScriptCoreInlineLibraryTests: XCTestCase {
  func testInlineLibraryLoadsOncePerSourceSession() async throws {
    let runtime = JavaScriptCoreSourceScriptRuntime()
    let library = SourceScriptLibrary(
      source: """
        globalThis.libraryLoadCount =
          (globalThis.libraryLoadCount || 0) + 1;
        function decorated(value) {
          return value + "|" + libraryLoadCount;
        }
        """
    )

    let first = try await runtime.evaluate(
      request(
        session: "source-1",
        library: library,
        script: "decorated('first')"
      ),
      host: nil
    )
    let second = try await runtime.evaluate(
      request(
        session: "source-1",
        library: library,
        script: "decorated('second')"
      ),
      host: nil
    )

    XCTAssertEqual(.string("first|1"), first)
    XCTAssertEqual(.string("second|1"), second)
  }

  func testLibrariesAreIsolatedBySourceSession() async throws {
    let runtime = JavaScriptCoreSourceScriptRuntime()

    let first = try await runtime.evaluate(
      request(
        session: "source-1",
        library: .init(
          source: "function sourcePrefix() { return 'one'; }"
        ),
        script: "sourcePrefix()"
      ),
      host: nil
    )
    let second = try await runtime.evaluate(
      request(
        session: "source-2",
        library: .init(
          source: "function sourcePrefix() { return 'two'; }"
        ),
        script: "sourcePrefix()"
      ),
      host: nil
    )

    XCTAssertEqual(.string("one"), first)
    XCTAssertEqual(.string("two"), second)
  }

  func testChangingLibraryReplacesSessionInsteadOfKeepingStaleGlobals()
    async throws
  {
    let runtime = JavaScriptCoreSourceScriptRuntime()
    _ = try await runtime.evaluate(
      request(
        session: "source-1",
        library: .init(
          source: """
            function version() { return "v1"; }
            function removedLater() { return "stale"; }
            """
        ),
        script: "version()"
      ),
      host: nil
    )

    let updated = try await runtime.evaluate(
      request(
        session: "source-1",
        library: .init(
          source: "function version() { return 'v2'; }"
        ),
        script: "version() + '|' + typeof removedLater"
      ),
      host: nil
    )

    XCTAssertEqual(.string("v2|undefined"), updated)
  }

  func testFailedLibraryDoesNotPoisonLaterValidSession() async throws {
    let runtime = JavaScriptCoreSourceScriptRuntime()

    do {
      _ = try await runtime.evaluate(
        request(
          session: "source-1",
          library: .init(source: "function broken("),
          script: "1"
        ),
        host: nil
      )
      XCTFail("Expected library evaluation failure")
    } catch let issue as SourceScriptIssue {
      XCTAssertEqual(.executionFailed, issue.code)
    }

    let recovered = try await runtime.evaluate(
      request(
        session: "source-1",
        library: .init(
          source: "function recovered() { return 'yes'; }"
        ),
        script: "recovered()"
      ),
      host: nil
    )
    XCTAssertEqual(.string("yes"), recovered)
  }

  private func request(
    session: String,
    library: SourceScriptLibrary,
    script: String
  ) -> SourceScriptRequest {
    SourceScriptRequest(
      sessionID: .init(rawValue: session),
      library: library,
      script: script
    )
  }
}
