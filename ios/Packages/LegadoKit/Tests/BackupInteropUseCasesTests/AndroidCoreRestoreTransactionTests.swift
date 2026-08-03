import BackupInteropUseCases
import Testing

@Suite("AndroidCoreRestoreTransactionTests")
struct AndroidCoreRestoreTransactionTests {
  @Test func databaseFailureRestoresCapturedExternalCheckpoint() async throws {
    let recorder = RestoreTransactionRecorder()

    await #expect(throws: RestoreTransactionFixtureError.database) {
      let _: Int = try await AndroidCoreRestoreTransaction.execute(
        capture: {
          await recorder.record("capture")
          return "old-state"
        },
        applyExternal: {
          await recorder.record("apply-external")
        },
        commitDatabase: {
          await recorder.record("commit-database")
          throw RestoreTransactionFixtureError.database
        },
        rollbackExternal: { checkpoint in
          await recorder.record("rollback-\(checkpoint)")
        }
      )
    }

    #expect(
      await recorder.events == [
        "capture", "apply-external", "commit-database", "rollback-old-state",
      ]
    )
  }

  @Test func externalFailureSkipsDatabaseAndRunsCompensation() async throws {
    let recorder = RestoreTransactionRecorder()

    await #expect(throws: RestoreTransactionFixtureError.external) {
      let _: Int = try await AndroidCoreRestoreTransaction.execute(
        capture: { "old-state" },
        applyExternal: {
          await recorder.record("apply-external")
          throw RestoreTransactionFixtureError.external
        },
        commitDatabase: {
          await recorder.record("unexpected-database")
          return 1
        },
        rollbackExternal: { checkpoint in
          await recorder.record("rollback-\(checkpoint)")
        }
      )
    }

    #expect(
      await recorder.events == ["apply-external", "rollback-old-state"]
    )
  }

  @Test func rollbackFailureIsNeverReportedAsOriginalFailure() async throws {
    await #expect(throws: AndroidCoreRestoreTransactionError.rollbackFailed) {
      let _: Int = try await AndroidCoreRestoreTransaction.execute(
        capture: { "old-state" },
        applyExternal: {},
        commitDatabase: {
          throw RestoreTransactionFixtureError.database
        },
        rollbackExternal: { _ in
          throw RestoreTransactionFixtureError.rollback
        }
      )
    }
  }
}

private actor RestoreTransactionRecorder {
  private(set) var events: [String] = []

  func record(_ event: String) {
    events.append(event)
  }
}

private enum RestoreTransactionFixtureError: Error {
  case external
  case database
  case rollback
}
