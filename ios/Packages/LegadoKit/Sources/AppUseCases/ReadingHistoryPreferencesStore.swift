import Observation

public struct ReadingHistoryPreferences:
  Codable, Equatable, Hashable, Sendable
{
  public var recordsReadingTime: Bool

  public init(recordsReadingTime: Bool = true) {
    self.recordsReadingTime = recordsReadingTime
  }
}

@MainActor
public protocol ReadingHistoryPreferencesRepository: AnyObject {
  func load() -> ReadingHistoryPreferences
  func save(_ preferences: ReadingHistoryPreferences)
}

@MainActor
@Observable
public final class ReadingHistoryPreferencesStore {
  public private(set) var value: ReadingHistoryPreferences

  private let repository: any ReadingHistoryPreferencesRepository

  public init(repository: any ReadingHistoryPreferencesRepository) {
    self.repository = repository
    value = repository.load()
  }

  public func setRecordsReadingTime(_ enabled: Bool) {
    replace(ReadingHistoryPreferences(recordsReadingTime: enabled))
  }

  public func replace(_ preferences: ReadingHistoryPreferences) {
    guard preferences != value else { return }
    value = preferences
    repository.save(preferences)
  }
}
