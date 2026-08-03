import Observation

public struct SourceSwitchPreferences:
  Codable, Equatable, Hashable, Sendable
{
  public var automaticallyRecoversMissingSource: Bool

  public init(automaticallyRecoversMissingSource: Bool = true) {
    self.automaticallyRecoversMissingSource =
      automaticallyRecoversMissingSource
  }
}

@MainActor
public protocol SourceSwitchPreferencesRepository: AnyObject {
  func load() -> SourceSwitchPreferences
  func save(_ preferences: SourceSwitchPreferences)
}

@MainActor
@Observable
public final class SourceSwitchPreferencesStore {
  public private(set) var value: SourceSwitchPreferences

  private let repository: any SourceSwitchPreferencesRepository

  public init(repository: any SourceSwitchPreferencesRepository) {
    self.repository = repository
    value = repository.load()
  }

  public func setAutomaticallyRecoversMissingSource(_ enabled: Bool) {
    replace(
      SourceSwitchPreferences(
        automaticallyRecoversMissingSource: enabled
      )
    )
  }

  public func replace(_ preferences: SourceSwitchPreferences) {
    value = preferences
    repository.save(preferences)
  }
}

public enum AutomaticSourceRecoveryDecision: Equatable, Sendable {
  case sourceAvailable
  case localBook
  case disabled
  case recover
}

public enum AutomaticSourceRecoveryPolicy {
  public static func decide(
    enabled: Bool,
    isLocalBook: Bool,
    sourceAvailable: Bool
  ) -> AutomaticSourceRecoveryDecision {
    if isLocalBook { return .localBook }
    if sourceAvailable { return .sourceAvailable }
    return enabled ? .recover : .disabled
  }
}
