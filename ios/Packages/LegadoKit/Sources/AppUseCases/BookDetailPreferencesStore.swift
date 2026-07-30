import Observation

public struct BookDetailPreferences: Codable, Equatable, Sendable {
  public var confirmsDeletion: Bool

  public init(confirmsDeletion: Bool = true) {
    self.confirmsDeletion = confirmsDeletion
  }
}

@MainActor
public protocol BookDetailPreferencesRepository: AnyObject {
  func load() -> BookDetailPreferences
  func save(_ preferences: BookDetailPreferences)
}

@MainActor
@Observable
public final class BookDetailPreferencesStore {
  public private(set) var value: BookDetailPreferences

  private let repository: any BookDetailPreferencesRepository

  public init(repository: any BookDetailPreferencesRepository) {
    self.repository = repository
    value = repository.load()
  }

  public func setConfirmsDeletion(_ enabled: Bool) {
    guard value.confirmsDeletion != enabled else {
      return
    }
    value.confirmsDeletion = enabled
    repository.save(value)
  }
}
