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
        pageAnimation: 3,
        layout: AndroidReaderLayoutProjection(
          textWeight: 1,
          letterSpacing: 0.3,
          paragraphSpacing: 8,
          paragraphIndent: "　",
          titleMode: 1,
          paddingTop: 20,
          paddingBottom: 10,
          paddingLeft: 30,
          paddingRight: 31
        )
      )
    )

    XCTAssertEqual(store.value.fontSize, 28)
    XCTAssertEqual(store.value.lineSpacing, 18)
    XCTAssertEqual(store.value.pageAnimation, 3)
    XCTAssertEqual(store.value.layout.textWeight, 1)
    XCTAssertEqual(store.value.layout.letterSpacing, 0.3)
    XCTAssertEqual(store.value.layout.paragraphSpacing, 8)
    XCTAssertEqual(store.value.layout.paragraphIndent, "　")
    XCTAssertEqual(store.value.layout.titleMode, 1)
    XCTAssertEqual(store.value.layout.paddingTop, 20)
    XCTAssertEqual(store.value.layout.paddingBottom, 10)
    XCTAssertEqual(store.value.layout.paddingLeft, 30)
    XCTAssertEqual(store.value.layout.paddingRight, 31)
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
