import Observation

@MainActor
public protocol WebDAVBackupCheckpointRepository: AnyObject {
  func loadLastBackupMilliseconds() -> Int64
  func saveLastBackupMilliseconds(_ value: Int64)
}

@MainActor
@Observable
public final class WebDAVBackupCheckpointStore {
  public private(set) var lastBackupMilliseconds: Int64

  private let repository: any WebDAVBackupCheckpointRepository

  public init(repository: any WebDAVBackupCheckpointRepository) {
    self.repository = repository
    lastBackupMilliseconds = max(
      0,
      repository.loadLastBackupMilliseconds()
    )
  }

  public func markBackup(_ milliseconds: Int64) {
    let normalized = max(0, milliseconds)
    guard normalized > lastBackupMilliseconds else { return }
    lastBackupMilliseconds = normalized
    repository.saveLastBackupMilliseconds(normalized)
  }

  public func reset() {
    lastBackupMilliseconds = 0
    repository.saveLastBackupMilliseconds(0)
  }
}
