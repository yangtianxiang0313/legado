import Observation

public struct SearchScopePreferences:
  Codable, Equatable, Hashable, Sendable
{
  public var serializedScope: String
  public var changeSourceGroup: String
  public var usesPrecisionSearch: Bool
  public var sourceConcurrency: Int

  public static let sourceConcurrencyRange = 1...999
  public static let androidMaximumEffectiveConcurrency = 9

  public init(
    serializedScope: String = "",
    changeSourceGroup: String = "",
    usesPrecisionSearch: Bool = false,
    sourceConcurrency: Int = 16
  ) {
    self.serializedScope = serializedScope
    self.changeSourceGroup = changeSourceGroup
    self.usesPrecisionSearch = usesPrecisionSearch
    self.sourceConcurrency = Self.normalizedConcurrency(sourceConcurrency)
  }

  public init(
    scope: SearchScopeSelection,
    usesPrecisionSearch: Bool = false,
    sourceConcurrency: Int = 16
  ) {
    serializedScope = scope.serialized
    changeSourceGroup = Self.androidSearchGroup(for: scope)
    self.usesPrecisionSearch = usesPrecisionSearch
    self.sourceConcurrency = Self.normalizedConcurrency(sourceConcurrency)
  }

  private enum CodingKeys: String, CodingKey {
    case serializedScope
    case changeSourceGroup
    case usesPrecisionSearch
    case sourceConcurrency
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    serializedScope = try container.decodeIfPresent(
      String.self,
      forKey: .serializedScope
    ) ?? ""
    changeSourceGroup = try container.decodeIfPresent(
      String.self,
      forKey: .changeSourceGroup
    ) ?? ""
    usesPrecisionSearch = try container.decodeIfPresent(
      Bool.self,
      forKey: .usesPrecisionSearch
    ) ?? false
    sourceConcurrency = Self.normalizedConcurrency(
      try container.decodeIfPresent(
        Int.self,
        forKey: .sourceConcurrency
      ) ?? 16
    )
  }

  public var scope: SearchScopeSelection {
    SearchScopeSelection(serialized: serializedScope)
  }

  public func includesChangeSource(group value: String) -> Bool {
    guard !changeSourceGroup.isEmpty else { return true }
    return value.split(separator: ",").contains {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
        == changeSourceGroup
    }
  }

  public var effectiveSourceConcurrency: Int {
    min(sourceConcurrency, Self.androidMaximumEffectiveConcurrency)
  }

  private static func normalizedConcurrency(_ value: Int) -> Int {
    min(max(value, sourceConcurrencyRange.lowerBound),
        sourceConcurrencyRange.upperBound)
  }

  private static func androidSearchGroup(
    for scope: SearchScopeSelection
  ) -> String {
    guard case .groups(let groups) = scope, groups.count == 1 else {
      return ""
    }
    return groups[0]
  }
}

@MainActor
public protocol SearchScopePreferencesRepository: AnyObject {
  func load() -> SearchScopePreferences
  func save(_ preferences: SearchScopePreferences)
}

@MainActor
@Observable
public final class SearchScopePreferencesStore {
  public private(set) var value: SearchScopePreferences

  private let repository: any SearchScopePreferencesRepository

  public init(repository: any SearchScopePreferencesRepository) {
    self.repository = repository
    value = repository.load()
  }

  public func setScope(_ scope: SearchScopeSelection) {
    replace(
      SearchScopePreferences(
        scope: scope,
        usesPrecisionSearch: value.usesPrecisionSearch,
        sourceConcurrency: value.sourceConcurrency
      )
    )
  }

  public func setUsesPrecisionSearch(_ enabled: Bool) {
    var updated = value
    updated.usesPrecisionSearch = enabled
    replace(updated)
  }

  public func setSourceConcurrency(_ count: Int) {
    var updated = value
    updated.sourceConcurrency = min(
      max(count, SearchScopePreferences.sourceConcurrencyRange.lowerBound),
      SearchScopePreferences.sourceConcurrencyRange.upperBound
    )
    replace(updated)
  }

  public func replace(_ preferences: SearchScopePreferences) {
    value = preferences
    repository.save(preferences)
  }
}
