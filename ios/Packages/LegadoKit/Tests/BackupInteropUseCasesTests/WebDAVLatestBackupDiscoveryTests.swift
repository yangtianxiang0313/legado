import BackupInteropUseCases
import IntegrationKit
import Testing

@Suite("WebDAVLatestBackupDiscoveryTests")
struct WebDAVLatestBackupDiscoveryTests {
  @Test func selectsNewestBackupIndependentOfServerOrdering() throws {
    let older = backup("backup-older.zip", modified: 120_000)
    let newest = backup("backup-newest.zip", modified: 300_001)
    let middle = backup("backup-middle.zip", modified: 240_000)

    let decision = WebDAVLatestBackupDiscovery.decide(
      files: [middle, older, newest],
      lastHandledMilliseconds: 200_000
    )

    let offer = try #require(decision.offer)
    #expect(offer.file == newest)
    #expect(offer.checkpointMilliseconds == 300_001)
  }

  @Test func requiresStrictlyMoreThanAndroidOneMinuteWindow() {
    let file = backup("backup.zip", modified: 160_000)

    #expect(
      WebDAVLatestBackupDiscovery.decide(
        files: [file],
        lastHandledMilliseconds: 100_000
      ) == .none
    )
    #expect(
      WebDAVLatestBackupDiscovery.decide(
        files: [backup("backup.zip", modified: 160_001)],
        lastHandledMilliseconds: 100_000
      ) != .none
    )
  }

  @Test func emptyOldAndAlreadyHandledBackupsDoNotPrompt() {
    #expect(
      WebDAVLatestBackupDiscovery.decide(
        files: [],
        lastHandledMilliseconds: 100_000
      ) == .none
    )
    #expect(
      WebDAVLatestBackupDiscovery.decide(
        files: [backup("backup.zip", modified: 99_999)],
        lastHandledMilliseconds: 100_000
      ) == .none
    )
    #expect(
      WebDAVLatestBackupDiscovery.decide(
        files: [backup("backup.zip", modified: 300_000)],
        lastHandledMilliseconds: 300_000
      ) == .none
    )
  }

  private func backup(
    _ name: String,
    modified: Int64
  ) -> WebDAVBackupFile {
    WebDAVBackupFile(
      name: name,
      size: 1,
      lastModifiedMilliseconds: modified
    )
  }
}

private extension WebDAVLatestBackupDiscoveryDecision {
  var offer: (file: WebDAVBackupFile, checkpointMilliseconds: Int64)? {
    guard case .offer(let file, let checkpoint) = self else { return nil }
    return (file, checkpoint)
  }
}
