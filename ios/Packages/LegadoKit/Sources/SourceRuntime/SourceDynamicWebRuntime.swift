import Foundation

public enum SourceDynamicWebPageMode: String, Equatable, Sendable {
  case loadURL = "load_url"
  case injectHTML = "inject_html"
}

public enum SourceDynamicWebCompletionKind: String, Equatable, Sendable {
  case javaScript = "javascript"
  case resource = "resource"
}

public struct SourceDynamicWebConfiguration: Equatable, Sendable {
  public let optionUseWebView: Bool
  public let invocationUseWebView: Bool
  public let javaScript: String?
  public let sourceRegex: String?
  public let userAgent: String?

  public init(
    optionUseWebView: Bool,
    invocationUseWebView: Bool,
    javaScript: String? = nil,
    sourceRegex: String? = nil,
    userAgent: String? = nil
  ) {
    self.optionUseWebView = optionUseWebView
    self.invocationUseWebView = invocationUseWebView
    self.javaScript = javaScript
    self.sourceRegex = sourceRegex
    self.userAgent = userAgent
  }

  public var usesDynamicPage: Bool {
    optionUseWebView && invocationUseWebView
  }
}

public struct SourceDynamicWebPageRequest: Equatable, Sendable {
  public let mode: SourceDynamicWebPageMode
  public let url: HTTPURL
  public let html: String?
  public let headers: HTTPHeaders
  public let userAgent: String?
  public let javaScript: String
  public let sourceRegex: String?

  public init(
    mode: SourceDynamicWebPageMode,
    url: HTTPURL,
    html: String?,
    headers: HTTPHeaders,
    userAgent: String?,
    javaScript: String,
    sourceRegex: String?
  ) {
    self.mode = mode
    self.url = url
    self.html = html
    self.headers = headers
    self.userAgent = userAgent
    self.javaScript = javaScript
    self.sourceRegex = sourceRegex
  }
}

public struct SourceDynamicWebPageResult: Equatable, Sendable {
  public let finalURL: HTTPURL
  public let value: String
  public let completionKind: SourceDynamicWebCompletionKind
  public let webCookie: String?

  public init(
    finalURL: HTTPURL,
    value: String,
    completionKind: SourceDynamicWebCompletionKind,
    webCookie: String?
  ) {
    self.finalURL = finalURL
    self.value = value
    self.completionKind = completionKind
    self.webCookie = webCookie
  }
}

public protocol SourceDynamicWebPagePort: Sendable {
  func execute(
    _ request: SourceDynamicWebPageRequest
  ) async throws -> SourceDynamicWebPageResult
}

public enum SourceDynamicWebStep: String, Equatable, Sendable {
  case httpTransport = "http_transport"
  case httpBootstrap = "http_bootstrap"
  case loadURL = "load_url"
  case injectHTML = "inject_html"
  case evaluateJavaScript = "evaluate_javascript"
  case resourceObserved = "resource_observed"
  case cookieBridged = "cookie_bridged"
  case completed
}

public struct SourceDynamicWebExecution: Equatable, Sendable {
  public let body: String
  public let finalURL: HTTPURL
  public let completionKind: SourceDynamicWebCompletionKind?
  public let webCookie: String?
  public let steps: [SourceDynamicWebStep]
}

public struct SourceDynamicWebExecutor: Sendable {
  public static let defaultJavaScript = "document.documentElement.outerHTML"

  private let transport: any HTTPTransport
  private let pagePort: any SourceDynamicWebPagePort

  public init(
    transport: any HTTPTransport,
    pagePort: any SourceDynamicWebPagePort
  ) {
    self.transport = transport
    self.pagePort = pagePort
  }

  public func execute(
    request: HTTPRequest,
    configuration: SourceDynamicWebConfiguration,
    cookieStore: SourceCookieStore? = nil,
    cookieStorageURL: HTTPURL? = nil
  ) async throws -> SourceDynamicWebExecution {
    guard configuration.usesDynamicPage else {
      let response = try await transport.execute(request)
      return SourceDynamicWebExecution(
        body: String(decoding: response.body.bytes, as: UTF8.self),
        finalURL: response.effectiveURL,
        completionKind: nil,
        webCookie: nil,
        steps: [.httpTransport, .completed]
      )
    }

    var steps: [SourceDynamicWebStep] = []
    let pageRequest: SourceDynamicWebPageRequest
    if request.method == .post {
      let response = try await transport.execute(request)
      steps.append(.httpBootstrap)
      pageRequest = SourceDynamicWebPageRequest(
        mode: .injectHTML,
        url: response.effectiveURL,
        html: String(decoding: response.body.bytes, as: UTF8.self),
        headers: request.headers,
        userAgent: configuration.userAgent,
        javaScript: configuration.javaScript ?? Self.defaultJavaScript,
        sourceRegex: configuration.sourceRegex
      )
      steps.append(.injectHTML)
    } else {
      pageRequest = SourceDynamicWebPageRequest(
        mode: .loadURL,
        url: request.url,
        html: nil,
        headers: request.headers,
        userAgent: configuration.userAgent,
        javaScript: configuration.javaScript ?? Self.defaultJavaScript,
        sourceRegex: configuration.sourceRegex
      )
      steps.append(.loadURL)
    }

    let result = try await pagePort.execute(pageRequest)
    switch result.completionKind {
    case .javaScript:
      steps.append(.evaluateJavaScript)
    case .resource:
      steps.append(.resourceObserved)
    }
    if
      let webCookie = result.webCookie,
      let cookieStore,
      let cookieStorageURL
    {
      try await cookieStore.replacePersistentCookie(
        webCookie,
        for: cookieStorageURL
      )
      steps.append(.cookieBridged)
    }
    steps.append(.completed)
    return SourceDynamicWebExecution(
      body: result.value,
      finalURL: result.finalURL,
      completionKind: result.completionKind,
      webCookie: result.webCookie,
      steps: steps
    )
  }
}
