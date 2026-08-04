import Foundation
import Observation
import SourceRuntime

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

public protocol DictionaryLookupExecuting: Sendable {
  func lookup(word: String, rule: DictionaryRule) async throws -> String
}

public struct SourceRuntimeDictionaryLookupExecutor:
  DictionaryLookupExecuting, Sendable
{
  private let pipeline: DictionaryLookupPipeline

  public init(pipeline: DictionaryLookupPipeline) {
    self.pipeline = pipeline
  }

  public func lookup(word: String, rule: DictionaryRule) async throws -> String {
    try await pipeline.lookup(
      word: word,
      rule: DictionaryRuntimeRule(
        name: rule.name,
        urlRule: rule.urlRule,
        showRule: rule.showRule
      )
    ).content
  }
}

@MainActor
@Observable
public final class DictionaryLookupStore {
  public private(set) var rules: [DictionaryRule] = []
  public private(set) var query = ""
  public private(set) var selectedRuleName: String?
  public private(set) var result: String?
  public private(set) var errorMessage: String?
  public private(set) var isLoading = false

  private let repository: any DictionaryRuleRepository
  private let executor: any DictionaryLookupExecuting

  public init(
    repository: any DictionaryRuleRepository,
    executor: any DictionaryLookupExecuting
  ) {
    self.repository = repository
    self.executor = executor
  }

  public func reload() async {
    do {
      rules = try await repository.dictionaryRules()
        .filter(\.isEnabled)
        .sorted {
          if $0.sortNumber != $1.sortNumber {
            return $0.sortNumber < $1.sortNumber
          }
          return $0.name < $1.name
        }
      if selectedRuleName == nil || !rules.contains(where: {
        $0.name == selectedRuleName
      }) {
        selectedRuleName = rules.first?.name
      }
      errorMessage = nil
    } catch {
      errorMessage = "无法读取词典规则"
    }
  }

  public func lookup(_ word: String, ruleName: String? = nil) async {
    let value = word.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else {
      errorMessage = "请输入要查询的词语"
      return
    }
    guard let rule = rules.first(where: {
      $0.name == (ruleName ?? selectedRuleName)
    }) else {
      errorMessage = "没有可用的词典规则"
      return
    }
    query = value
    selectedRuleName = rule.name
    result = nil
    errorMessage = nil
    isLoading = true
    defer { isLoading = false }
    do {
      result = try await executor.lookup(word: value, rule: rule)
    } catch {
      errorMessage = "词典查询失败"
    }
  }

  @discardableResult
  public func importRules(_ values: [DictionaryRule]) async -> Bool {
    do {
      try await repository.restoreAndroidDictionaryRules(values)
      await reload()
      return true
    } catch {
      errorMessage = "无法导入词典规则"
      return false
    }
  }
}
