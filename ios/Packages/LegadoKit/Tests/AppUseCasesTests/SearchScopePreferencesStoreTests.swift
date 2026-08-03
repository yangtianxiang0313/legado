@testable import AppUseCases
import XCTest

@MainActor
final class SearchScopePreferencesStoreTests: XCTestCase {
  func testRestoredAndroidScopeSeedsSessionAndChangesPersist() {
    let repository = SearchScopePreferencesRepositoryStub(
      loaded: SearchScopePreferences(
        serializedScope: "科幻",
        changeSourceGroup: "科幻"
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
    XCTAssertEqual(repository.saved.last, SearchScopePreferences())
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

private struct SearchBooksExecutorStub: SearchBooksExecuting {
  func search(
    query: String,
    scope: SearchScopeSelection
  ) async throws -> [SearchResult] {
    []
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
