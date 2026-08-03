import IntegrationKit

public enum WebDAVLatestBackupDiscoveryDecision: Sendable, Equatable {
  case none
  case offer(file: WebDAVBackupFile, checkpointMilliseconds: Int64)
}

/// Mirrors Android `AppWebDav.lastBackUp` + `MainActivity.backupSync` without
/// importing Activity or dialog concerns into the package layer.
public enum WebDAVLatestBackupDiscovery {
  public static let androidMinimumAdvanceMilliseconds: Int64 = 60_000

  public static func decide(
    files: [WebDAVBackupFile],
    lastHandledMilliseconds: Int64,
    minimumAdvanceMilliseconds: Int64 = androidMinimumAdvanceMilliseconds
  ) -> WebDAVLatestBackupDiscoveryDecision {
    guard let latest = files.max(by: isEarlier) else { return .none }
    let checkpoint = max(0, lastHandledMilliseconds)
    let minimumAdvance = max(0, minimumAdvanceMilliseconds)
    guard latest.lastModifiedMilliseconds > checkpoint else { return .none }
    guard latest.lastModifiedMilliseconds - checkpoint > minimumAdvance else {
      return .none
    }
    return .offer(
      file: latest,
      checkpointMilliseconds: latest.lastModifiedMilliseconds
    )
  }

  private static func isEarlier(
    _ lhs: WebDAVBackupFile,
    _ rhs: WebDAVBackupFile
  ) -> Bool {
    if lhs.lastModifiedMilliseconds != rhs.lastModifiedMilliseconds {
      return lhs.lastModifiedMilliseconds < rhs.lastModifiedMilliseconds
    }
    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
  }
}
