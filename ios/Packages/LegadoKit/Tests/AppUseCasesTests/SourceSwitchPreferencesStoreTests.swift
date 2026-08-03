@testable import AppUseCases
import XCTest

@MainActor
final class SourceSwitchPreferencesStoreTests: XCTestCase {
  func testPersistsRestoredAutomaticRecoveryPreference() {
    let repository = SourceSwitchPreferencesRepositoryStub()
    let store = SourceSwitchPreferencesStore(repository: repository)

    store.setAutomaticallyRecoversMissingSource(false)

    XCTAssertFalse(store.value.automaticallyRecoversMissingSource)
    XCTAssertEqual(
      repository.saved,
      [SourceSwitchPreferences(automaticallyRecoversMissingSource: false)]
    )
  }

  func testRecoveryOnlyRunsForRemoteBookWithMissingSourceWhenEnabled() {
    XCTAssertEqual(
      AutomaticSourceRecoveryPolicy.decide(
        enabled: true,
        isLocalBook: false,
        sourceAvailable: false
      ),
      .recover
    )
    XCTAssertEqual(
      AutomaticSourceRecoveryPolicy.decide(
        enabled: false,
        isLocalBook: false,
        sourceAvailable: false
      ),
      .disabled
    )
    XCTAssertEqual(
      AutomaticSourceRecoveryPolicy.decide(
        enabled: true,
        isLocalBook: true,
        sourceAvailable: false
      ),
      .localBook
    )
    XCTAssertEqual(
      AutomaticSourceRecoveryPolicy.decide(
        enabled: true,
        isLocalBook: false,
        sourceAvailable: true
      ),
      .sourceAvailable
    )
  }
}

@MainActor
private final class SourceSwitchPreferencesRepositoryStub:
  SourceSwitchPreferencesRepository
{
  var saved: [SourceSwitchPreferences] = []

  func load() -> SourceSwitchPreferences { SourceSwitchPreferences() }

  func save(_ preferences: SourceSwitchPreferences) {
    saved.append(preferences)
  }
}
