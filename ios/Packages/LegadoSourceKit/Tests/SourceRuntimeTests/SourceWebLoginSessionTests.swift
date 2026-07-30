import XCTest

@testable import SourceRuntime

final class SourceWebLoginSessionTests: XCTestCase {
  func testPrepareResolvesRelativeLoginAndSeedsStoredCookie() async throws {
    let store = SourceCookieStore()
    let storageURL = try HTTPURL("https://www.example.com/source")
    try await store.replacePersistentCookie(
      "persisted=stored; shared=old",
      for: storageURL
    )
    try await store.replaceSessionCookie(
      "shared=session; volatile=memory",
      for: storageURL
    )
    let headers = HTTPHeaders([
      try HTTPHeader(name: "user-agent", value: "LegadoLogin/1"),
      try HTTPHeader(name: "x-source", value: "login"),
    ])

    let preparation = try await SourceWebLoginSession(
      sourceURL: storageURL.absoluteString,
      loginURL: "/account/login",
      headers: headers,
      cookieStore: store
    ).prepare()

    XCTAssertEqual(preparation.storageURL, storageURL)
    XCTAssertEqual(
      preparation.loginURL.absoluteString,
      "https://www.example.com/account/login"
    )
    XCTAssertEqual(preparation.headers, headers)
    XCTAssertEqual(
      preparation.cookie,
      "persisted=stored; shared=session; volatile=memory"
    )
  }

  func testBrowserCookieReplacesPersistentLayerAndUnlocksRequests()
    async throws
  {
    let store = SourceCookieStore()
    let session = SourceWebLoginSession(
      sourceURL: "https://www.example.com/source",
      loginURL: "https://auth.example.com/login",
      cookieStore: store
    )

    try await session.synchronize(
      browserCookie: "authenticated=yes; account=reader"
    )

    let request = HTTPRequest(
      method: .get,
      url: try HTTPURL("https://api.example.com/search")
    )
    let preparation = try await SourceCookieRequestCoordinator.prepare(
      request: request,
      storageURL: request.url,
      explicitCookie: "",
      store: store,
      enabledCookieJar: true
    )
    XCTAssertEqual(
      preparation.networkCookie,
      "authenticated=yes; account=reader"
    )
  }

  func testClearRemovesCookiesForFollowingSourceRequests() async throws {
    let store = SourceCookieStore()
    let session = SourceWebLoginSession(
      sourceURL: "https://www.example.com/source",
      loginURL: "/login",
      cookieStore: store
    )
    try await session.synchronize(browserCookie: "authenticated=yes")

    try await session.clear()

    let snapshot = try await store.snapshot(
      for: HTTPURL("https://api.example.com/search")
    )
    XCTAssertEqual(snapshot.combinedCookie, "")
    XCTAssertNil(snapshot.sessionCookie)
  }

  func testRejectsScriptLoginAndInvalidURLs() async throws {
    let store = SourceCookieStore()

    do {
      _ = try await SourceWebLoginSession(
        sourceURL: "https://example.com/source",
        loginURL: "@js:function login() {}",
        cookieStore: store
      ).prepare()
      XCTFail("Expected script login to be rejected")
    } catch {
      XCTAssertEqual(
        error as? SourceWebLoginSessionError,
        .scriptLoginUnsupported
      )
    }
    do {
      _ = try await SourceWebLoginSession(
        sourceURL: "not a URL",
        loginURL: "/login",
        cookieStore: store
      ).prepare()
      XCTFail("Expected invalid source URL to be rejected")
    } catch {
      XCTAssertEqual(
        error as? SourceWebLoginSessionError,
        .invalidSourceURL
      )
    }
  }
}
