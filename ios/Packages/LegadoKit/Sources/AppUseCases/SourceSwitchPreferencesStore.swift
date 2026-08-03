import Observation

public struct SourceSwitchPreferences:
  Codable, Equatable, Hashable, Sendable
{
  public var automaticallyRecoversMissingSource: Bool
  public var requiresAuthorMatch: Bool

  public init(
    automaticallyRecoversMissingSource: Bool = true,
    requiresAuthorMatch: Bool = false
  ) {
    self.automaticallyRecoversMissingSource =
      automaticallyRecoversMissingSource
    self.requiresAuthorMatch = requiresAuthorMatch
  }

  private enum CodingKeys: String, CodingKey {
    case automaticallyRecoversMissingSource
    case requiresAuthorMatch
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    automaticallyRecoversMissingSource = try container.decodeIfPresent(
      Bool.self,
      forKey: .automaticallyRecoversMissingSource
    ) ?? true
    requiresAuthorMatch = try container.decodeIfPresent(
      Bool.self,
      forKey: .requiresAuthorMatch
    ) ?? false
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
    var updated = value
    updated.automaticallyRecoversMissingSource = enabled
    replace(updated)
  }

  public func setRequiresAuthorMatch(_ enabled: Bool) {
    var updated = value
    updated.requiresAuthorMatch = enabled
    replace(updated)
  }

  public func replace(_ preferences: SourceSwitchPreferences) {
    value = preferences
    repository.save(preferences)
  }
}

public enum SourceSwitchCandidateIdentityPolicy {
  public static func matches(
    currentTitle: String,
    currentAuthor: String,
    candidateTitle: String,
    candidateAuthor: String,
    requiresAuthorMatch: Bool
  ) -> Bool {
    guard candidateTitle == currentTitle else { return false }
    return !requiresAuthorMatch || candidateAuthor.contains(currentAuthor)
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
