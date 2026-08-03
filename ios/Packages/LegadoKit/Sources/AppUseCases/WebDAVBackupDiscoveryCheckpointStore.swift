import Observation

@MainActor
public protocol WebDAVBackupDiscoveryCheckpointRepository: AnyObject {
  func loadLastHandledMilliseconds() -> Int64
  func saveLastHandledMilliseconds(_ value: Int64)
}

@MainActor
@Observable
public final class WebDAVBackupDiscoveryCheckpointStore {
  public private(set) var lastHandledMilliseconds: Int64

  private let repository: any WebDAVBackupDiscoveryCheckpointRepository

  public init(repository: any WebDAVBackupDiscoveryCheckpointRepository) {
    self.repository = repository
    lastHandledMilliseconds = max(
      0,
      repository.loadLastHandledMilliseconds()
    )
  }

  public func markHandled(_ milliseconds: Int64) {
    let normalized = max(0, milliseconds)
    guard normalized > lastHandledMilliseconds else { return }
    lastHandledMilliseconds = normalized
    repository.saveLastHandledMilliseconds(normalized)
  }

  public func reset() {
    lastHandledMilliseconds = 0
    repository.saveLastHandledMilliseconds(0)
  }
}
