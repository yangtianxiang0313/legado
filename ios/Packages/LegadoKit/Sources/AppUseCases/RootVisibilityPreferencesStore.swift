import Observation

public enum DefaultHomePage: String, Codable, CaseIterable, Sendable {
  case bookshelf
  case explore
  case rss
  case settings = "my"
}

public struct RootVisibilityPreferences: Codable, Equatable, Sendable {
  public var showsExplore: Bool
  public var showsRSS: Bool
  public var defaultHomePage: DefaultHomePage

  public init(
    showsExplore: Bool = true,
    showsRSS: Bool = true,
    defaultHomePage: DefaultHomePage = .bookshelf
  ) {
    self.showsExplore = showsExplore
    self.showsRSS = showsRSS
    self.defaultHomePage = defaultHomePage
  }

  public var effectiveDefaultHomePage: DefaultHomePage {
    switch defaultHomePage {
    case .explore where !showsExplore, .rss where !showsRSS:
      .bookshelf
    default:
      defaultHomePage
    }
  }

  private enum CodingKeys: String, CodingKey {
    case showsExplore
    case showsRSS
    case defaultHomePage
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    showsExplore = try container.decodeIfPresent(
      Bool.self,
      forKey: .showsExplore
    ) ?? true
    showsRSS = try container.decodeIfPresent(
      Bool.self,
      forKey: .showsRSS
    ) ?? true
    defaultHomePage = try container.decodeIfPresent(
      DefaultHomePage.self,
      forKey: .defaultHomePage
    ) ?? .bookshelf
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

  public func setDefaultHomePage(_ page: DefaultHomePage) {
    update { $0.defaultHomePage = page }
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
