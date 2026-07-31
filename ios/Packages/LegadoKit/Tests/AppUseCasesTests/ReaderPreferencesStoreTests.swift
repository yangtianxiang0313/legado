@testable import AppUseCases
import ReaderCore
import XCTest

@MainActor
final class ReaderPreferencesStoreTests: XCTestCase {
  func testStoreLoadsNormalizesAndPersistsEveryMutation() {
    let repository = InMemoryReaderPreferencesRepository(
      value: ReaderPreferences(
        darkTheme: true,
        brightness: 0.6,
        fontSize: 24,
        lineSpacing: 10,
        autoPageEnabled: false
      )
    )
    let store = ReaderPreferencesStore(repository: repository)

    XCTAssertTrue(store.value.darkTheme)
    store.setFontSize(100)
    store.setLineSpacing(4)
    store.setAutoPageEnabled(true)

    XCTAssertEqual(store.value.fontSize, 32)
    XCTAssertEqual(store.value.lineSpacing, 4)
    XCTAssertTrue(store.value.autoPageEnabled)
    XCTAssertEqual(repository.value, store.value)
    XCTAssertEqual(repository.saveCount, 4)
  }
}

@MainActor
final class RootVisibilityPreferencesStoreTests: XCTestCase {
  func testStorePersistsOptionalRootChanges() {
    let repository = InMemoryRootVisibilityPreferencesRepository(
      value: RootVisibilityPreferences()
    )
    let store = RootVisibilityPreferencesStore(repository: repository)

    store.setShowsExplore(false)
    store.setShowsRSS(false)

    XCTAssertEqual(
      store.value,
      RootVisibilityPreferences(showsExplore: false, showsRSS: false)
    )
    XCTAssertEqual(repository.value, store.value)
    XCTAssertEqual(repository.saveCount, 2)
  }
}

@MainActor
private final class InMemoryReaderPreferencesRepository:
  ReaderPreferencesRepository
{
  var value: ReaderPreferences
  var saveCount = 0

  init(value: ReaderPreferences) {
    self.value = value
  }

  func load() -> ReaderPreferences {
    value
  }

  func save(_ preferences: ReaderPreferences) {
    value = preferences
    saveCount += 1
  }
}

@MainActor
private final class InMemoryRootVisibilityPreferencesRepository:
  RootVisibilityPreferencesRepository
{
  var value: RootVisibilityPreferences
  var saveCount = 0

  init(value: RootVisibilityPreferences) {
    self.value = value
  }

  func load() -> RootVisibilityPreferences { value }

  func save(_ preferences: RootVisibilityPreferences) {
    value = preferences
    saveCount += 1
  }
}
