import AppUseCases
import ReaderCore
import XCTest

@MainActor
final class ReaderConfigInteropTests: XCTestCase {
  func testApplyingAndroidProjectionUpdatesOnlyPortableReaderPreferences() {
    let repository = PreferencesRepositoryStub(
      value: ReaderPreferences(
        darkTheme: true,
        brightness: 0.7,
        fontSize: 20,
        lineSpacing: 12,
        autoPageEnabled: true
      )
    )
    let store = ReaderPreferencesStore(repository: repository)

    store.apply(
      AndroidReaderConfigProjection(
        fontSize: 28,
        lineSpacing: 18,
        pageAnimation: 3
      )
    )

    XCTAssertEqual(store.value.fontSize, 28)
    XCTAssertEqual(store.value.lineSpacing, 18)
    XCTAssertEqual(store.value.pageAnimation, 3)
    XCTAssertTrue(store.value.darkTheme)
    XCTAssertEqual(store.value.brightness, 0.7)
    XCTAssertTrue(store.value.autoPageEnabled)
    XCTAssertEqual(repository.value, store.value)
  }
}

@MainActor
private final class PreferencesRepositoryStub: ReaderPreferencesRepository {
  var value: ReaderPreferences
  init(value: ReaderPreferences) { self.value = value }
  func load() -> ReaderPreferences { value }
  func save(_ preferences: ReaderPreferences) { value = preferences }
}
