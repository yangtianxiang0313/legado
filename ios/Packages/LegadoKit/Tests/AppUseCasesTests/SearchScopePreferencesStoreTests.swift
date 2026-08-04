@testable import AppUseCases
import Foundation
import XCTest

@MainActor
final class SearchScopePreferencesStoreTests: XCTestCase {
  func testRestoredAndroidScopeSeedsSessionAndChangesPersist() {
    let repository = SearchScopePreferencesRepositoryStub(
      loaded: SearchScopePreferences(
        serializedScope: "科幻",
        changeSourceGroup: "科幻",
        usesPrecisionSearch: true
      )
    )
    let store = SearchScopePreferencesStore(repository: repository)
    let session = SearchSession(
      groups: ["奇幻", "科幻"],
      executor: SearchBooksExecutorStub(),
      scopePreferences: store
    )

    XCTAssertEqual(session.scope, .groups(["科幻"]))

    session.selectAllSources()

    XCTAssertEqual(store.value.serializedScope, "")
    XCTAssertEqual(store.value.changeSourceGroup, "")
    XCTAssertTrue(store.value.usesPrecisionSearch)
  }

  func testLegacyStoredScopeDefaultsPrecisionSearchToOff() throws {
    let decoded = try JSONDecoder().decode(
      SearchScopePreferences.self,
      from: Data(
        #"{"serializedScope":"科幻","changeSourceGroup":"科幻"}"#.utf8
      )
    )

    XCTAssertFalse(decoded.usesPrecisionSearch)
    XCTAssertEqual(decoded.sourceConcurrency, 16)
    XCTAssertEqual(decoded.effectiveSourceConcurrency, 9)
  }

  func testSourceConcurrencyMatchesAndroidStoredAndEffectiveRanges() {
    let repository = SearchScopePreferencesRepositoryStub(
      loaded: SearchScopePreferences(sourceConcurrency: 16)
    )
    let store = SearchScopePreferencesStore(repository: repository)

    XCTAssertEqual(store.value.sourceConcurrency, 16)
    XCTAssertEqual(store.value.effectiveSourceConcurrency, 9)

    store.setSourceConcurrency(0)
    XCTAssertEqual(store.value.sourceConcurrency, 1)
    XCTAssertEqual(store.value.effectiveSourceConcurrency, 1)

    store.setSourceConcurrency(2_000)
    XCTAssertEqual(store.value.sourceConcurrency, 999)
    XCTAssertEqual(store.value.effectiveSourceConcurrency, 9)
  }

  func testChangingConcurrencyImmediatelyRebuildsSearchExecutor() {
    let repository = SearchScopePreferencesRepositoryStub(
      loaded: SearchScopePreferences(sourceConcurrency: 16)
    )
    let store = SearchScopePreferencesStore(repository: repository)
    let recorder = SearchExecutorFactoryRecorder()
    let session = SearchSession(
      groups: [],
      scopePreferences: store,
      executorFactory: { concurrency in
        recorder.record(concurrency)
        return SearchBooksExecutorStub()
      }
    )

    XCTAssertEqual(recorder.values, [9])

    session.setSourceConcurrency(3)

    XCTAssertEqual(store.value.sourceConcurrency, 3)
    XCTAssertEqual(recorder.values, [9, 3])
  }

  func testAndroidPrecisionProjectionRanksAndFiltersResults() {
    let results = [
      result("unrelated", name: "银河", author: "甲", origins: 9),
      result("contains-low", name: "星河外传", author: "乙", origins: 1),
      result("exact-low", name: "星河", author: "丙", origins: 1),
      result("contains-high", name: "远方", author: "星河作者", origins: 4),
      result("exact-high", name: "别名", author: "星河", origins: 3),
    ]

    XCTAssertEqual(
      AndroidPrecisionSearchPolicy.project(
        results,
        keyword: "星河",
        precision: false
      ).map(\.id),
      ["exact-high", "exact-low", "contains-high", "contains-low", "unrelated"]
    )
    XCTAssertEqual(
      AndroidPrecisionSearchPolicy.project(
        results,
        keyword: "星河",
        precision: true
      ).map(\.id),
      ["exact-high", "exact-low", "contains-high", "contains-low"]
    )
  }

  func testPrecisionToggleImmediatelyRepeatsCurrentSearch() async {
    let repository = SearchScopePreferencesRepositoryStub(
      loaded: SearchScopePreferences()
    )
    let store = SearchScopePreferencesStore(repository: repository)
    let executor = SearchBooksExecutorStub(results: [
      result("match", name: "星河纪事", author: "林川", origins: 1),
      result("other", name: "远方", author: "他人", origins: 1),
    ])
    let session = SearchSession(
      groups: [],
      executor: executor,
      scopePreferences: store
    )
    session.query = "星河"
    session.search()
    await waitUntilIdle(session)
    XCTAssertEqual(session.results.map(\.id), ["match", "other"])

    session.setUsesPrecisionSearch(true)
    await waitUntilIdle(session)

    XCTAssertEqual(session.results.map(\.id), ["match"])
    XCTAssertTrue(store.value.usesPrecisionSearch)
    let callCount = await executor.callCount()
    XCTAssertEqual(callCount, 2)
  }

  func testSingleGroupMatchesAndroidSearchGroupDerivation() {
    XCTAssertEqual(
      SearchScopePreferences(scope: .groups(["科幻"])),
      SearchScopePreferences(
        serializedScope: "科幻",
        changeSourceGroup: "科幻"
      )
    )
    XCTAssertEqual(
      SearchScopePreferences(scope: .groups(["科幻", "奇幻"]))
        .changeSourceGroup,
      ""
    )
    XCTAssertEqual(
      SearchScopePreferences(
        scope: .source(name: "站点", identifier: "https://source")
      ).changeSourceGroup,
      ""
    )

    let restored = SearchScopePreferences(
      serializedScope: "科幻",
      changeSourceGroup: "科幻"
    )
    XCTAssertTrue(restored.includesChangeSource(group: "奇幻,科幻"))
    XCTAssertFalse(restored.includesChangeSource(group: "历史"))
  }
}

private func result(
  _ id: String,
  name: String,
  author: String,
  origins: Int
) -> SearchResult {
  SearchResult(
    id: id,
    name: name,
    author: author,
    kind: "",
    lastChapter: "",
    intro: "",
    bookURL: "https://example.invalid/\(id)",
    coverURL: nil,
    origin: "source",
    originName: "source",
    originCount: origins
  )
}

@MainActor
private func waitUntilIdle(_ session: SearchSession) async {
  while session.loadingState == .loading {
    await Task.yield()
  }
}

private actor SearchBooksExecutorStub: SearchBooksExecuting {
  let results: [SearchResult]
  private var calls = 0

  init(results: [SearchResult] = []) {
    self.results = results
  }

  func search(
    query: String,
    scope: SearchScopeSelection
  ) async throws -> [SearchResult] {
    calls += 1
    return results
  }

  func callCount() -> Int { calls }
}

private final class SearchExecutorFactoryRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [Int] = []

  var values: [Int] {
    lock.withLock { storage }
  }

  func record(_ value: Int) {
    lock.withLock { storage.append(value) }
  }
}

@MainActor
private final class SearchScopePreferencesRepositoryStub:
  SearchScopePreferencesRepository
{
  let loaded: SearchScopePreferences
  var saved: [SearchScopePreferences] = []

  init(loaded: SearchScopePreferences) {
    self.loaded = loaded
  }

  func load() -> SearchScopePreferences { loaded }

  func save(_ preferences: SearchScopePreferences) {
    saved.append(preferences)
  }
}
