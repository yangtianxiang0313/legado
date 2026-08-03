@testable import AppUseCases
import XCTest

@MainActor
final class ReadingHistoryPreferencesStoreTests: XCTestCase {
  func testPersistsRestoredAndroidReadingHistoryPreference() {
    let repository = ReadingHistoryPreferencesRepositoryStub()
    let store = ReadingHistoryPreferencesStore(repository: repository)

    XCTAssertTrue(store.value.recordsReadingTime)

    store.setRecordsReadingTime(false)

    XCTAssertFalse(store.value.recordsReadingTime)
    XCTAssertEqual(repository.saved, [ReadingHistoryPreferences(recordsReadingTime: false)])
  }
}

@MainActor
private final class ReadingHistoryPreferencesRepositoryStub:
  ReadingHistoryPreferencesRepository
{
  var saved: [ReadingHistoryPreferences] = []

  func load() -> ReadingHistoryPreferences {
    ReadingHistoryPreferences()
  }

  func save(_ preferences: ReadingHistoryPreferences) {
    saved.append(preferences)
  }
}
