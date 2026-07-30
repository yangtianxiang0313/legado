import AppUseCases
import XCTest

@MainActor
final class BookDetailPreferencesStoreTests: XCTestCase {
  func testDefaultsToConfirmationAndPersistsChanges() {
    let repository = InMemoryBookDetailPreferencesRepository()
    let store = BookDetailPreferencesStore(repository: repository)

    XCTAssertTrue(store.value.confirmsDeletion)

    store.setConfirmsDeletion(false)

    XCTAssertFalse(store.value.confirmsDeletion)
    let reopened = BookDetailPreferencesStore(repository: repository)
    XCTAssertFalse(reopened.value.confirmsDeletion)
  }
}

@MainActor
private final class InMemoryBookDetailPreferencesRepository:
  BookDetailPreferencesRepository
{
  private var value = BookDetailPreferences()

  func load() -> BookDetailPreferences {
    value
  }

  func save(_ preferences: BookDetailPreferences) {
    value = preferences
  }
}
