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
    XCTAssertFalse(decoded.loadsBookInfo)
    XCTAssertFalse(decoded.loadsTableOfContents)
    XCTAssertFalse(decoded.loadsChapterWordCount)
  }

  func testCandidateProbePlanMatchesAndroidImplicationChain() {
    XCTAssertEqual(
      SourceSwitchCandidateProbePlan(
        preferences: SourceSwitchPreferences(loadsBookInfo: true)
      ),
      SourceSwitchCandidateProbePlan(
        loadsBookInfo: true,
        loadsTableOfContents: false,
        loadsChapterWordCount: false
      )
    )
    XCTAssertEqual(
      SourceSwitchCandidateProbePlan(
        preferences: SourceSwitchPreferences(
          loadsChapterWordCount: true
        )
      ),
      SourceSwitchCandidateProbePlan(
        loadsBookInfo: true,
        loadsTableOfContents: true,
        loadsChapterWordCount: true
      )
    )
  }

  func testWordCountSortingMatchesAndroidComparatorTail() {
    let values = [
      preview("order", count: 500, chapter: 30, order: 0),
      preview("long-old", count: 1_200, chapter: 10, order: 2),
      preview("long-new", count: 1_100, chapter: 20, order: 3),
      preview("long-new-more", count: 1_500, chapter: 20, order: 4),
    ]

    XCTAssertEqual(
      AndroidSourceSwitchCandidatePolicy.sorted(
        values,
        loadsChapterWordCount: true
      ).map(\.id),
      ["long-new-more", "long-new", "long-old", "order"]
    )
    XCTAssertEqual(
      AndroidSourceSwitchCandidatePolicy.sorted(
        values,
        loadsChapterWordCount: false
      ).map(\.id),
      ["order", "long-old", "long-new", "long-new-more"]
    )
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

private extension SourceSwitchCandidateProbePlan {
  init(
    loadsBookInfo: Bool,
    loadsTableOfContents: Bool,
    loadsChapterWordCount: Bool
  ) {
    self.init(
      preferences: SourceSwitchPreferences(
        loadsBookInfo: loadsBookInfo,
        loadsTableOfContents: loadsTableOfContents,
        loadsChapterWordCount: loadsChapterWordCount
      )
    )
  }
}

private func preview(
  _ id: String,
  count: Int,
  chapter: Int,
  order: Int
) -> SourceSwitchCandidatePreview {
  SourceSwitchCandidatePreview(
    source: BookSourceDraft(sourceURL: id, name: id),
    candidate: ShelfBookCandidate(
      name: "书",
      author: "作者",
      kind: "",
      lastChapter: "",
      intro: "",
      bookURL: id,
      coverURL: nil,
      originName: id,
      sourceID: id
    ),
    probedChapterNumber: chapter,
    chapterWordCount: count,
    originOrder: order
  )
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
