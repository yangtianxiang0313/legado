import Foundation

public struct DictionaryRule: Codable, Equatable, Identifiable, Sendable {
  public var id: String { name }
  public var name: String
  public var urlRule: String
  public var showRule: String
  public var isEnabled: Bool
  public var sortNumber: Int

  public init(
    name: String,
    urlRule: String,
    showRule: String = "",
    isEnabled: Bool = true,
    sortNumber: Int = 0
  ) {
    self.name = name
    self.urlRule = urlRule
    self.showRule = showRule
    self.isEnabled = isEnabled
    self.sortNumber = sortNumber
  }
}

public protocol DictionaryRuleRepository: Sendable {
  func dictionaryRules() async throws -> [DictionaryRule]
  func restoreAndroidDictionaryRules(_ values: [DictionaryRule]) async throws
}

public extension DictionaryRuleRepository {
  func dictionaryRules() async throws -> [DictionaryRule] { [] }
  func restoreAndroidDictionaryRules(_ values: [DictionaryRule]) async throws {}
}
