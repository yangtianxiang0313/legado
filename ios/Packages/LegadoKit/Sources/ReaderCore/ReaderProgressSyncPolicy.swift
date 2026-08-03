import LibraryDomain

public enum ReaderProgressSyncDecision: Equatable, Sendable {
  case applyCloud
  case requireRollbackConfirmation
}

public struct ReaderProgressSyncResolution: Equatable, Sendable {
  public let beforeConfirmation: ReadingPosition
  public let confirmationRequested: Bool
  public let confirmationAccepted: Bool
  public let final: ReadingPosition

  public init(
    beforeConfirmation: ReadingPosition,
    confirmationRequested: Bool,
    confirmationAccepted: Bool,
    final: ReadingPosition
  ) {
    self.beforeConfirmation = beforeConfirmation
    self.confirmationRequested = confirmationRequested
    self.confirmationAccepted = confirmationAccepted
    self.final = final
  }
}

/// Android single-book WebDAV progress compatibility.
///
/// Progress ordering is lexicographic: chapter first, then the character
/// offset. A cloud rollback is never automatic, but may be explicitly
/// accepted by the presentation layer.
public enum AndroidReaderProgressSyncPolicy {
  public static func decision(
    local: ReadingPosition,
    cloud: ReadingPosition
  ) -> ReaderProgressSyncDecision {
    if cloud.chapterIndex < local.chapterIndex
      || (
        cloud.chapterIndex == local.chapterIndex
          && cloud.characterOffset < local.characterOffset
      )
    {
      return .requireRollbackConfirmation
    }
    return .applyCloud
  }

  public static func resolve(
    local: ReadingPosition,
    cloud: ReadingPosition,
    confirmRollback: Bool
  ) -> ReaderProgressSyncResolution {
    switch decision(local: local, cloud: cloud) {
    case .applyCloud:
      return ReaderProgressSyncResolution(
        beforeConfirmation: cloud,
        confirmationRequested: false,
        confirmationAccepted: false,
        final: cloud
      )
    case .requireRollbackConfirmation:
      return ReaderProgressSyncResolution(
        beforeConfirmation: local,
        confirmationRequested: true,
        confirmationAccepted: confirmRollback,
        final: confirmRollback ? cloud : local
      )
    }
  }
}
