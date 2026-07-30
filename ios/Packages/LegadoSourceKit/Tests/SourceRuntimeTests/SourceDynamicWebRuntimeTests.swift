import XCTest

@testable import SourceRuntime

final class SourceDynamicWebRuntimeTests: XCTestCase {
  func testInvocationGateFallsBackToHTTPTransport() async throws {
    let transport = DynamicWebProbeTransport(
      responseBody: "raw-http-response\n"
    )
    let page = DynamicWebProbePagePort(
      result: try pageResult(value: "must-not-run")
    )
    let execution = try await SourceDynamicWebExecutor(
      transport: transport,
      pagePort: page
    ).execute(
      request: try request(path: "/http"),
      configuration: SourceDynamicWebConfiguration(
        optionUseWebView: true,
        invocationUseWebView: false,
        javaScript: SourceDynamicWebExecutor.defaultJavaScript
      )
    )

    XCTAssertEqual(execution.body, "raw-http-response\n")
    XCTAssertEqual(execution.steps, [.httpTransport, .completed])
    let transportCount = await transport.requestCount
    let pageCount = await page.requestCount
    XCTAssertEqual(transportCount, 1)
    XCTAssertEqual(pageCount, 0)
  }

  func testOptionGateFallsBackEvenWhenInvocationAllowsWebView() async throws {
    let transport = DynamicWebProbeTransport(
      responseBody: "option-disabled-http-response\n"
    )
    let page = DynamicWebProbePagePort(
      result: try pageResult(value: "must-not-run")
    )
    let execution = try await SourceDynamicWebExecutor(
      transport: transport,
      pagePort: page
    ).execute(
      request: try request(path: "/option-disabled"),
      configuration: SourceDynamicWebConfiguration(
        optionUseWebView: false,
        invocationUseWebView: true
      )
    )

    XCTAssertEqual(execution.body, "option-disabled-http-response\n")
    let transportCount = await transport.requestCount
    let pageCount = await page.requestCount
    XCTAssertEqual(transportCount, 1)
    XCTAssertEqual(pageCount, 0)
  }

  func testGETLoadsPageWithoutUsingHTTPBootstrap() async throws {
    let transport = DynamicWebProbeTransport(responseBody: "unused")
    let page = DynamicWebProbePagePort(
      result: try pageResult(value: "动态值")
    )
    let execution = try await SourceDynamicWebExecutor(
      transport: transport,
      pagePort: page
    ).execute(
      request: try request(path: "/custom-js"),
      configuration: SourceDynamicWebConfiguration(
        optionUseWebView: true,
        invocationUseWebView: true,
        javaScript: "document.getElementById('value').textContent",
        userAgent: "SourceLab-Dynamic-Web/1.0"
      )
    )

    XCTAssertEqual(execution.body, "动态值")
    XCTAssertEqual(
      execution.steps,
      [.loadURL, .evaluateJavaScript, .completed]
    )
    let transportCount = await transport.requestCount
    let recordedPageRequest = await page.lastRequest
    XCTAssertEqual(transportCount, 0)
    let pageRequest = try XCTUnwrap(recordedPageRequest)
    XCTAssertEqual(pageRequest.mode, .loadURL)
    XCTAssertNil(pageRequest.html)
    XCTAssertEqual(pageRequest.userAgent, "SourceLab-Dynamic-Web/1.0")
  }

  func testPOSTBootstrapsHTTPThenInjectsResponseHTML() async throws {
    let transport = DynamicWebProbeTransport(
      responseBody: "<section id=\"post-result\">post-bootstrap</section>"
    )
    let page = DynamicWebProbePagePort(
      result: try pageResult(value: "post-bootstrap")
    )
    let execution = try await SourceDynamicWebExecutor(
      transport: transport,
      pagePort: page
    ).execute(
      request: try request(
        path: "/post",
        method: .post,
        body: "{\"probe\":\"post-bootstrap\"}"
      ),
      configuration: SourceDynamicWebConfiguration(
        optionUseWebView: true,
        invocationUseWebView: true,
        javaScript: "document.getElementById('post-result').textContent"
      )
    )

    XCTAssertEqual(execution.body, "post-bootstrap")
    XCTAssertEqual(
      execution.steps,
      [.httpBootstrap, .injectHTML, .evaluateJavaScript, .completed]
    )
    let transportCount = await transport.requestCount
    let recordedPageRequest = await page.lastRequest
    XCTAssertEqual(transportCount, 1)
    let pageRequest = try XCTUnwrap(recordedPageRequest)
    XCTAssertEqual(pageRequest.mode, .injectHTML)
    XCTAssertEqual(
      pageRequest.html,
      "<section id=\"post-result\">post-bootstrap</section>"
    )
  }

  func testResourceCompletionAndCookieBridgeAreExplicit() async throws {
    let transport = DynamicWebProbeTransport(responseBody: "unused")
    let page = DynamicWebProbePagePort(
      result: SourceDynamicWebPageResult(
        finalURL: try HTTPURL("http://sourcelab.test/dynamic/sniff.html"),
        value: "http://sourcelab.test/dynamic/sniff-target.js",
        completionKind: .resource,
        webCookie: "websession=from-webview"
      )
    )
    let store = SourceCookieStore()
    let storageURL = try HTTPURL("http://127.0.0.1/dynamic")
    let execution = try await SourceDynamicWebExecutor(
      transport: transport,
      pagePort: page
    ).execute(
      request: try request(path: "/sniff.html"),
      configuration: SourceDynamicWebConfiguration(
        optionUseWebView: true,
        invocationUseWebView: true,
        sourceRegex: ".*/dynamic/sniff-target\\.js"
      ),
      cookieStore: store,
      cookieStorageURL: storageURL
    )

    XCTAssertEqual(execution.completionKind, .resource)
    XCTAssertEqual(
      execution.steps,
      [.loadURL, .resourceObserved, .cookieBridged, .completed]
    )
    let snapshot = try await store.snapshot(for: storageURL)
    XCTAssertEqual(snapshot.persistentCookie, "websession=from-webview")
  }

  private func request(
    path: String,
    method: HTTPMethod = .get,
    body: String? = nil
  ) throws -> HTTPRequest {
    HTTPRequest(
      method: method,
      url: try HTTPURL("http://sourcelab.test/dynamic\(path)"),
      headers: HTTPHeaders([
        try HTTPHeader(name: "x-source", value: "dynamic-web")
      ]),
      body: body.map { HTTPBody(Data($0.utf8)) }
    )
  }

  private func pageResult(value: String) throws -> SourceDynamicWebPageResult {
    SourceDynamicWebPageResult(
      finalURL: try HTTPURL("http://sourcelab.test/dynamic/result"),
      value: value,
      completionKind: .javaScript,
      webCookie: nil
    )
  }
}

private actor DynamicWebProbeTransport: HTTPTransport {
  private let responseBody: String
  private(set) var requestCount = 0

  init(responseBody: String) {
    self.responseBody = responseBody
  }

  func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
    requestCount += 1
    return try HTTPResponse(
      statusCode: 200,
      effectiveURL: request.url,
      body: HTTPBody(Data(responseBody.utf8))
    )
  }
}

private actor DynamicWebProbePagePort: SourceDynamicWebPagePort {
  private let result: SourceDynamicWebPageResult
  private(set) var requestCount = 0
  private(set) var lastRequest: SourceDynamicWebPageRequest?

  init(result: SourceDynamicWebPageResult) {
    self.result = result
  }

  func execute(
    _ request: SourceDynamicWebPageRequest
  ) async throws -> SourceDynamicWebPageResult {
    requestCount += 1
    lastRequest = request
    return result
  }
}
