public enum AndroidCoreRestoreTransactionError: Error, Equatable, Sendable {
  case rollbackFailed
}

public enum AndroidCoreRestoreTransaction {
  public static func execute<Checkpoint, Result>(
    capture: () async throws -> Checkpoint,
    applyExternal: () async throws -> Void,
    commitDatabase: () async throws -> Result,
    rollbackExternal: (Checkpoint) async throws -> Void
  ) async throws -> Result {
    let checkpoint = try await capture()
    do {
      try await applyExternal()
      return try await commitDatabase()
    } catch {
      let originalError = error
      do {
        try await rollbackExternal(checkpoint)
      } catch {
        throw AndroidCoreRestoreTransactionError.rollbackFailed
      }
      throw originalError
    }
  }
}
