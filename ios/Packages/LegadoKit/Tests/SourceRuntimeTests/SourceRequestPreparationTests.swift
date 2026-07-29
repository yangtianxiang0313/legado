import XCTest

@testable import SourceRuntime

final class SourceRequestPreparationTests: XCTestCase {
  func testExactNameOverlayRetainsCaseDistinctHeaders() throws {
    let preparation = try SourceRequestPreparer.prepare(
      request: HTTPRequest(
        method: .get,
        url: try HTTPURL("http://sourcelab.test/request")
      ),
      inheritedHeaders: try fields([
        ("X-Layer", "source"),
        ("X-Case", "source-uppercase"),
      ]),
      optionHeaders: try fields([
        ("X-Layer", "option"),
        ("x-case", "option-lowercase"),
      ]),
      persistentCookie: "",
      enabledCookieJar: false,
      retry: 0
    )

    XCTAssertEqual(
      preparation.constructedHeaders,
      try fields([
        ("X-Case", "source-uppercase"),
        ("x-case", "option-lowercase"),
        ("X-Layer", "option"),
      ])
    )
    XCTAssertEqual(
      preparation.constructedRequest.headers.values(for: "x-case"),
      ["source-uppercase", "option-lowercase"]
    )
  }

  func testCookieJarHasSeparateResolvedAndNetworkStages() throws {
    let preparation = try SourceRequestPreparer.prepare(
      request: HTTPRequest(
        method: .get,
        url: try HTTPURL("http://sourcelab.test/request")
      ),
      inheritedHeaders: try fields([
        ("Cookie", "explicit=source; shared=source"),
      ]),
      optionHeaders: try fields([
        ("Cookie", "explicit=option; shared=option"),
      ]),
      persistentCookie: "persisted=stored; shared=stored",
      enabledCookieJar: true,
      retry: 2
    )

    XCTAssertEqual(
      preparation.resolvedHeaders,
      try fields([
        ("Cookie", "persisted=stored; shared=option; explicit=option"),
        ("CookieJar", "1"),
      ])
    )
    XCTAssertEqual(
      preparation.networkHeaders,
      try fields([
        ("Cookie", "persisted=stored; shared=stored; explicit=option"),
      ])
    )
    XCTAssertEqual(preparation.retry, 2)
  }

  func testRetryExecutesInitialAttemptPlusConfiguredRetries() async throws {
    let transport = AlwaysUnavailableTransport()
    let execution = try await SourceRequestExecutor(transport: transport).execute(
      HTTPRequest(
        method: .get,
        url: try HTTPURL("http://sourcelab.test/retry")
      ),
      retry: 2
    )

    XCTAssertEqual(execution.response.statusCode, 503)
    XCTAssertEqual(execution.attemptCount, 3)
    let attemptCount = await transport.count
    XCTAssertEqual(attemptCount, 3)
  }

  func testDefaultRetryExecutesOnce() async throws {
    let transport = AlwaysUnavailableTransport()
    let execution = try await SourceRequestExecutor(transport: transport).execute(
      HTTPRequest(
        method: .get,
        url: try HTTPURL("http://sourcelab.test/retry")
      ),
      retry: SourceRequestPlan(
        request: HTTPRequest(
          method: .get,
          url: try HTTPURL("http://sourcelab.test/retry")
        ),
        body: nil,
        formFields: []
      ).retry
    )

    XCTAssertEqual(execution.attemptCount, 1)
    let attemptCount = await transport.count
    XCTAssertEqual(attemptCount, 1)
  }

  func testURLOptionCompilesRetryIntoRequestPlan() throws {
    let plan = try SourceRequestCompiler.compile(
      template: #"http://sourcelab.test/retry, {"retry":2}"#,
      keyword: "unused"
    )

    XCTAssertEqual(plan.retry, 2)
  }

  func testNegativeRetryFailsClosed() {
    XCTAssertThrowsError(
      try SourceRequestCompiler.compile(
        template: #"http://sourcelab.test/retry, {"retry":-1}"#,
        keyword: "unused"
      )
    ) { error in
      XCTAssertEqual(error as? SourceRequestPreparationError, .invalidRetry)
    }
  }

  private func fields(
    _ values: [(String, String)]
  ) throws -> [SourceHeaderField] {
    try values.map { try SourceHeaderField(name: $0.0, value: $0.1) }
  }
}

private actor AlwaysUnavailableTransport: HTTPTransport {
  private(set) var count = 0

  func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
    count += 1
    return try HTTPResponse(
      statusCode: 503,
      effectiveURL: request.url,
      body: HTTPBody(Data("retryable\n".utf8))
    )
  }
}
