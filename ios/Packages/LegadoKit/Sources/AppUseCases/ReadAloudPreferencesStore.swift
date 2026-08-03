import Observation
import ReaderCore

@MainActor
public protocol ReadAloudPreferencesRepository: AnyObject {
  func load() -> ReadAloudPreferences
  func save(_ preferences: ReadAloudPreferences)
}

@MainActor
@Observable
public final class ReadAloudPreferencesStore {
  public private(set) var value: ReadAloudPreferences

  private let repository: any ReadAloudPreferencesRepository

  public init(repository: any ReadAloudPreferencesRepository) {
    self.repository = repository
    let loaded = repository.load().normalized()
    value = loaded
    repository.save(loaded)
  }

  public func setFollowsSystemRate(_ enabled: Bool) {
    update { $0.followsSystemRate = enabled }
  }

  public func setSpeechRatePreference(_ value: Int) {
    update { $0.speechRatePreference = value }
  }

  public func replace(_ preferences: ReadAloudPreferences) {
    let updated = preferences.normalized()
    guard updated != value else { return }
    value = updated
    repository.save(updated)
  }

  private func update(_ mutation: (inout ReadAloudPreferences) -> Void) {
    var updated = value
    mutation(&updated)
    replace(updated)
  }
}
