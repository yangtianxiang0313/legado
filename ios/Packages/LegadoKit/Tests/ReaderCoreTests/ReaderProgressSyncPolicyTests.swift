import LibraryDomain
import Testing
@testable import ReaderCore

@Suite("Android WebDAV reader progress sync")
struct ReaderProgressSyncPolicyTests {
  @Test("cloud progress ahead applies without confirmation")
  func appliesCloudAhead() {
    let result = AndroidReaderProgressSyncPolicy.resolve(
      local: position(1, 40),
      cloud: position(2, 15),
      confirmRollback: false
    )

    #expect(result.beforeConfirmation == position(2, 15))
    #expect(!result.confirmationRequested)
    #expect(!result.confirmationAccepted)
    #expect(result.final == position(2, 15))
  }

  @Test("older position in the same chapter requires confirmation")
  func rejectsUnconfirmedPositionRollback() {
    let result = AndroidReaderProgressSyncPolicy.resolve(
      local: position(1, 90),
      cloud: position(1, 30),
      confirmRollback: false
    )

    #expect(result.beforeConfirmation == position(1, 90))
    #expect(result.confirmationRequested)
    #expect(!result.confirmationAccepted)
    #expect(result.final == position(1, 90))
  }

  @Test("older chapter may replace local progress after confirmation")
  func acceptsChapterRollback() {
    let result = AndroidReaderProgressSyncPolicy.resolve(
      local: position(2, 20),
      cloud: position(0, 70),
      confirmRollback: true
    )

    #expect(result.beforeConfirmation == position(2, 20))
    #expect(result.confirmationRequested)
    #expect(result.confirmationAccepted)
    #expect(result.final == position(0, 70))
  }

  @Test("equal cloud progress follows Android automatic apply path")
  func appliesEqualProgress() {
    let result = AndroidReaderProgressSyncPolicy.resolve(
      local: position(1, 20),
      cloud: position(1, 20),
      confirmRollback: true
    )

    #expect(!result.confirmationRequested)
    #expect(!result.confirmationAccepted)
    #expect(result.final == position(1, 20))
  }

  private func position(_ chapter: Int, _ offset: Int) -> ReadingPosition {
    ReadingPosition(chapterIndex: chapter, characterOffset: offset)
  }
}
