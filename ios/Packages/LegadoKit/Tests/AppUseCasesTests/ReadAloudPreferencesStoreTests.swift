@testable import AppUseCases
import ReaderCore
import XCTest

@MainActor
final class ReadAloudPreferencesStoreTests: XCTestCase {
  func testPersistsRestoredAndroidPreferencesAndEffectiveRate() {
    let repository = ReadAloudPreferencesRepositoryStub()
    let store = ReadAloudPreferencesStore(repository: repository)

    store.replace(
      ReadAloudPreferences(
        followsSystemRate: false,
        speechRatePreference: 15
      )
    )

    XCTAssertEqual(store.value.relativeRate, 2)
    XCTAssertEqual(repository.saved.last?.followsSystemRate, false)
    XCTAssertEqual(repository.saved.last?.speechRatePreference, 15)
  }
}

@MainActor
private final class ReadAloudPreferencesRepositoryStub:
  ReadAloudPreferencesRepository
{
  var saved: [ReadAloudPreferences] = []

  func load() -> ReadAloudPreferences {
    ReadAloudPreferences()
  }

  func save(_ preferences: ReadAloudPreferences) {
    saved.append(preferences)
  }
}
