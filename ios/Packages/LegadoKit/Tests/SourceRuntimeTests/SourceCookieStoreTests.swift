import XCTest

@testable import SourceRuntime

final class SourceCookieStoreTests: XCTestCase {
  func testParserMatchesAndroidBoundaryRules() {
    let pairs = SourceCookieParser.parse(
      "a=1; empty=; blank=   ; lone; equals=a=b; null=null; "
        + "duplicate=first; duplicate=second"
    )

    XCTAssertEqual(
      pairs,
      [
        SourceCookiePair(name: "a", value: "1"),
        SourceCookiePair(name: "equals", value: "a=b"),
        SourceCookiePair(name: "null", value: "null"),
        SourceCookiePair(name: "duplicate", value: "second"),
      ]
    )
    XCTAssertEqual(
      SourceCookieParser.serialize(pairs),
      "a=1; equals=a=b; null=null; duplicate=second"
    )
  }

  func testSessionLayerOverridesPersistentLayerWithoutMovingKey() async throws {
    let store = SourceCookieStore()
    let url = try HTTPURL("http://127.0.0.1/cookie")
    try await store.replacePersistentCookie(
      "persisted=stored; shared=persistent",
      for: url
    )
    try await store.saveResponse(
      setCookieHeaders: [
        "session=memory; Path=/",
        "shared=session; Path=/",
      ],
      for: url,
      enabledCookieJar: true
    )

    let snapshot = try await store.snapshot(for: url)
    XCTAssertEqual(snapshot.persistentCookie, "persisted=stored; shared=persistent")
    XCTAssertEqual(snapshot.sessionCookie, "session=memory; shared=session")
    XCTAssertEqual(
      snapshot.combinedCookie,
      "persisted=stored; shared=session; session=memory"
    )
  }

  func testEnabledRequestReloadsStoreAtNetworkBoundary() async throws {
    let store = try await seededStore()
    let storageURL = try HTTPURL("http://127.0.0.1/cookie")
    let preparation = try await SourceCookieRequestCoordinator.prepare(
      request: HTTPRequest(
        method: .get,
        url: try HTTPURL("http://sourcelab.test/cookie/enabled"),
        headers: HTTPHeaders([
          try HTTPHeader(name: "x-source", value: "cookie-session")
        ])
      ),
      storageURL: storageURL,
      explicitCookie: "explicit=source; shared=explicit",
      store: store,
      enabledCookieJar: true
    )

    XCTAssertEqual(
      preparation.resolvedCookie,
      "persisted=stored; shared=explicit; session=memory; explicit=source"
    )
    XCTAssertEqual(
      preparation.networkCookie,
      "persisted=stored; shared=session; session=memory; explicit=source"
    )
    XCTAssertTrue(preparation.markerPresent)
    XCTAssertFalse(preparation.networkMarkerPresent)
    XCTAssertEqual(preparation.resolvedRequest.headers.values(for: "cookiejar"), ["1"])
    XCTAssertEqual(preparation.networkRequest.headers.values(for: "cookiejar"), [])
  }

  func testDisabledRequestKeepsExplicitPrecedenceAndIgnoresResponse() async throws {
    let store = try await seededStore()
    let storageURL = try HTTPURL("http://127.0.0.1/cookie")
    let preparation = try await SourceCookieRequestCoordinator.prepare(
      request: HTTPRequest(
        method: .get,
        url: try HTTPURL("http://sourcelab.test/cookie/disabled")
      ),
      storageURL: storageURL,
      explicitCookie: "explicit=source; shared=explicit",
      store: store,
      enabledCookieJar: false
    )
    try await store.saveResponse(
      setCookieHeaders: ["ignored=server; Path=/"],
      for: storageURL,
      enabledCookieJar: false
    )

    XCTAssertEqual(preparation.networkCookie, preparation.resolvedCookie)
    XCTAssertFalse(preparation.markerPresent)
    let snapshot = try await store.snapshot(for: storageURL)
    XCTAssertFalse(snapshot.combinedCookie.contains("ignored=server"))
  }

  func testResponseClassificationFlattensMetadataAndRetainsExpiredValue() async throws {
    let store = SourceCookieStore()
    let url = try HTTPURL("http://127.0.0.1/cookie")
    try await store.saveResponse(
      setCookieHeaders: [
        "pathOnly=value; Max-Age=3600; Path=/restricted",
        "expired=value; Max-Age=0; Path=/",
      ],
      for: url,
      enabledCookieJar: true
    )

    let snapshot = try await store.snapshot(for: url)
    XCTAssertEqual(snapshot.persistentCookie, "pathOnly=value; expired=value")
    XCTAssertEqual(snapshot.sessionCookie, "")
    XCTAssertEqual(snapshot.combinedCookie, "pathOnly=value; expired=value")
  }

  func testRemovalAffectsBothLayersAndDomainRemovalResetsSessionPresence() async throws {
    let store = try await seededStore()
    let url = try HTTPURL("http://127.0.0.1/cookie")

    try await store.removeCookie(named: "shared", for: url)
    var snapshot = try await store.snapshot(for: url)
    XCTAssertEqual(snapshot.persistentCookie, "persisted=stored")
    XCTAssertEqual(snapshot.sessionCookie, "session=memory")

    try await store.removeCookies(for: url)
    snapshot = try await store.snapshot(for: url)
    XCTAssertEqual(snapshot.persistentCookie, "")
    XCTAssertNil(snapshot.sessionCookie)
  }

  func testRegistrableDomainSharesCookiesButOtherSiteIsIsolated() async throws {
    let store = SourceCookieStore()
    let write = try HTTPURL("https://www.example.com/path")
    let sameSite = try HTTPURL("https://api.example.com/other")
    let otherSite = try HTTPURL("https://www.example.org/path")
    try await store.replacePersistentCookie("registrable=shared", for: write)

    let writeSnapshot = try await store.snapshot(for: write)
    let sameSiteSnapshot = try await store.snapshot(for: sameSite)
    let otherSiteSnapshot = try await store.snapshot(for: otherSite)
    XCTAssertEqual(writeSnapshot.domain, "example.com")
    XCTAssertEqual(sameSiteSnapshot.combinedCookie, "registrable=shared")
    XCTAssertEqual(otherSiteSnapshot.combinedCookie, "")
  }

  private func seededStore() async throws -> SourceCookieStore {
    let store = SourceCookieStore()
    let url = try HTTPURL("http://127.0.0.1/cookie")
    try await store.replacePersistentCookie(
      "persisted=stored; shared=persistent",
      for: url
    )
    try await store.saveResponse(
      setCookieHeaders: [
        "session=memory; Path=/",
        "shared=session; Path=/",
      ],
      for: url,
      enabledCookieJar: true
    )
    return store
  }
}
