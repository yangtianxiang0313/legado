public enum SourceStringResponseSessionError: Error, Equatable, Sendable {
  case dynamicPageUnavailable
}

public struct SourceStringResponseSession: Sendable {
  private let transport: any HTTPTransport
  private let cookieStore: SourceCookieStore
  private let dynamicWebPagePort: (any SourceDynamicWebPagePort)?

  public init(
    transport: any HTTPTransport,
    cookieStore: SourceCookieStore,
    dynamicWebPagePort: (any SourceDynamicWebPagePort)? = nil
  ) {
    self.transport = transport
    self.cookieStore = cookieStore
    self.dynamicWebPagePort = dynamicWebPagePort
  }

  public func load(
    _ plan: SourceRequestPlan,
    enabledCookieJar: Bool,
    javaScript: String? = nil,
    sourceRegex: String? = nil
  ) async throws -> SourceStringResponse {
    guard plan.useWebView else {
      let response = try await SourceRequestSession(
        transport: transport,
        cookieStore: cookieStore
      ).execute(
        plan,
        enabledCookieJar: enabledCookieJar
      ).response
      return try SourceStringResponseNormalizer.normalize(response)
    }
    guard let dynamicWebPagePort else {
      throw SourceStringResponseSessionError.dynamicPageUnavailable
    }

    let explicitCookie = plan.request.headers
      .values(for: "cookie")
      .joined(separator: "; ")
    let preparation = try await SourceCookieRequestCoordinator.prepare(
      request: plan.request,
      storageURL: plan.request.url,
      explicitCookie: explicitCookie,
      store: cookieStore,
      enabledCookieJar: enabledCookieJar
    )
    let execution = try await SourceDynamicWebExecutor(
      transport: SourceDynamicBootstrapTransport(
        transport: transport,
        cookieStore: cookieStore,
        retry: plan.retry,
        enabledCookieJar: enabledCookieJar
      ),
      pagePort: dynamicWebPagePort
    ).execute(
      request: preparation.networkRequest,
      configuration: SourceDynamicWebConfiguration(
        optionUseWebView: true,
        invocationUseWebView: true,
        javaScript: plan.webJS ?? javaScript,
        sourceRegex: sourceRegex,
        userAgent: preparation.networkRequest.headers
          .values(for: "user-agent").last
      ),
      cookieStore: cookieStore,
      cookieStorageURL: plan.request.url
    )
    return SourceStringResponse(
      body: execution.body,
      finalURL: execution.finalURL
    )
  }
}

private struct SourceDynamicBootstrapTransport: HTTPTransport {
  let transport: any HTTPTransport
  let cookieStore: SourceCookieStore
  let retry: Int
  let enabledCookieJar: Bool

  func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
    let execution = try await SourceRequestExecutor(
      transport: transport
    ).execute(request, retry: retry)
    try await cookieStore.saveResponse(
      setCookieHeaders: execution.response.headers.values(
        for: "set-cookie"
      ),
      for: execution.effectiveURL,
      enabledCookieJar: enabledCookieJar
    )
    return execution.response
  }
}
