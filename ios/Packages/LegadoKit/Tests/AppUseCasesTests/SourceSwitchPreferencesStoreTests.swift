@testable import AppUseCases
import Foundation
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

  func testPersistsAuthorMatchWithoutResettingAutomaticRecovery() {
    let repository = SourceSwitchPreferencesRepositoryStub()
    let store = SourceSwitchPreferencesStore(repository: repository)

    store.setAutomaticallyRecoversMissingSource(false)
    store.setRequiresAuthorMatch(true)

    XCTAssertEqual(
      store.value,
      SourceSwitchPreferences(
        automaticallyRecoversMissingSource: false,
        requiresAuthorMatch: true
      )
    )
  }

  func testDecodesLegacyStoredPreferenceWithAndroidDefaults() throws {
    let decoded = try JSONDecoder().decode(
      SourceSwitchPreferences.self,
      from: Data(
        #"{"automaticallyRecoversMissingSource":false}"#.utf8
      )
    )

    XCTAssertFalse(decoded.automaticallyRecoversMissingSource)
    XCTAssertFalse(decoded.requiresAuthorMatch)
  }

  func testCandidateIdentityAlwaysChecksTitleAndOptionallyAuthor() {
    XCTAssertTrue(
      SourceSwitchCandidateIdentityPolicy.matches(
        currentTitle: "星河纪事",
        currentAuthor: "林川",
        candidateTitle: "星河纪事",
        candidateAuthor: "另一作者",
        requiresAuthorMatch: false
      )
    )
    XCTAssertFalse(
      SourceSwitchCandidateIdentityPolicy.matches(
        currentTitle: "星河纪事",
        currentAuthor: "林川",
        candidateTitle: "同名之外的结果",
        candidateAuthor: "林川",
        requiresAuthorMatch: false
      )
    )
    XCTAssertTrue(
      SourceSwitchCandidateIdentityPolicy.matches(
        currentTitle: "星河纪事",
        currentAuthor: "林川",
        candidateTitle: "星河纪事",
        candidateAuthor: "作者：林川 著",
        requiresAuthorMatch: true
      )
    )
    XCTAssertFalse(
      SourceSwitchCandidateIdentityPolicy.matches(
        currentTitle: "星河纪事",
        currentAuthor: "林川",
        candidateTitle: "星河纪事",
        candidateAuthor: "另一作者",
        requiresAuthorMatch: true
      )
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
