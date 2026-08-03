import Observation

public struct RootVisibilityPreferences: Codable, Equatable, Sendable {
  public var showsExplore: Bool
  public var showsRSS: Bool

  public init(showsExplore: Bool = true, showsRSS: Bool = true) {
    self.showsExplore = showsExplore
    self.showsRSS = showsRSS
  }
}

@MainActor
public protocol RootVisibilityPreferencesRepository: AnyObject {
  func load() -> RootVisibilityPreferences
  func save(_ preferences: RootVisibilityPreferences)
}

@MainActor
@Observable
public final class RootVisibilityPreferencesStore {
  public private(set) var value: RootVisibilityPreferences

  private let repository: any RootVisibilityPreferencesRepository

  public init(repository: any RootVisibilityPreferencesRepository) {
    self.repository = repository
    value = repository.load()
  }

  public func setShowsExplore(_ enabled: Bool) {
    update { $0.showsExplore = enabled }
  }

  public func setShowsRSS(_ enabled: Bool) {
    update { $0.showsRSS = enabled }
  }

  public func replace(_ preferences: RootVisibilityPreferences) {
    guard preferences != value else { return }
    value = preferences
    repository.save(preferences)
  }

  private func update(_ mutation: (inout RootVisibilityPreferences) -> Void) {
    var updated = value
    mutation(&updated)
    guard updated != value else { return }
    value = updated
    repository.save(updated)
  }
}
