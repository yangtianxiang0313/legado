import Foundation
import Observation
import ReaderCore

public struct ReaderReplacementRule: Identifiable, Equatable, Codable, Sendable {
  public let id: String
  public var name: String
  public var pattern: String
  public var replacement: String
  public var scope: String?
  public var excludeScope: String?
  public var appliesToTitle: Bool
  public var appliesToContent: Bool
  public var isEnabled: Bool
  public var isRegex: Bool
  public var order: Int

  public init(
    id: String = UUID().uuidString.lowercased(),
    name: String,
    pattern: String,
    replacement: String,
    scope: String? = nil,
    excludeScope: String? = nil,
    appliesToTitle: Bool = false,
    appliesToContent: Bool = true,
    isEnabled: Bool = true,
    isRegex: Bool = true,
    order: Int = 0
  ) {
    self.id = id
    self.name = name
    self.pattern = pattern
    self.replacement = replacement
    self.scope = scope
    self.excludeScope = excludeScope
    self.appliesToTitle = appliesToTitle
    self.appliesToContent = appliesToContent
    self.isEnabled = isEnabled
    self.isRegex = isRegex
    self.order = order
  }

  public var contentRule: ReaderContentReplacementRule {
    ReaderContentReplacementRule(
      name: name,
      pattern: pattern,
      replacement: replacement,
      scope: scope,
      excludeScope: excludeScope,
      appliesToTitle: appliesToTitle,
      appliesToContent: appliesToContent,
      isEnabled: isEnabled,
      isRegex: isRegex,
      order: order
    )
  }

  public var validationMessage: String? {
    guard !pattern.isEmpty else { return "匹配内容不能为空" }
    if isRegex, (try? NSRegularExpression(pattern: pattern)) == nil {
      return "正则表达式无效"
    }
    return nil
  }
}

public protocol ReaderReplacementRuleRepository: Sendable {
  func replacementRules() async throws -> [ReaderReplacementRule]
  func saveReplacementRule(_ rule: ReaderReplacementRule) async throws
  func deleteReplacementRule(id: String) async throws
  func resetReplacementRules() async throws
}

public extension ReaderReplacementRuleRepository {
  func replacementRules() async throws -> [ReaderReplacementRule] {
    []
  }

  func saveReplacementRule(_ rule: ReaderReplacementRule) async throws {
    throw ReaderReplacementRuleFailure.unsupportedRepository
  }

  func deleteReplacementRule(id: String) async throws {
    throw ReaderReplacementRuleFailure.unsupportedRepository
  }

  func resetReplacementRules() async throws {
    throw ReaderReplacementRuleFailure.unsupportedRepository
  }
}

public enum ReaderReplacementRuleFailure: Error, Equatable {
  case unsupportedRepository
  case invalidRule(String)
}

@MainActor
@Observable
public final class ReaderReplacementRuleStore {
  public private(set) var rules: [ReaderReplacementRule] = []
  public private(set) var errorMessage: String?

  private let repository: any ReaderReplacementRuleRepository

  public init(repository: any ReaderReplacementRuleRepository) {
    self.repository = repository
  }

  public func reload() async {
    do {
      rules = try await repository.replacementRules()
      errorMessage = nil
    } catch {
      errorMessage = "无法读取替换规则"
    }
  }

  @discardableResult
  public func save(_ rule: ReaderReplacementRule) async -> Bool {
    if let message = rule.validationMessage {
      errorMessage = message
      return false
    }
    do {
      try await repository.saveReplacementRule(rule)
      await reload()
      return true
    } catch {
      errorMessage = "无法保存替换规则"
      return false
    }
  }

  @discardableResult
  public func delete(id: String) async -> Bool {
    do {
      try await repository.deleteReplacementRule(id: id)
      await reload()
      return true
    } catch {
      errorMessage = "无法删除替换规则"
      return false
    }
  }

  @discardableResult
  public func setEnabled(id: String, enabled: Bool) async -> Bool {
    guard var rule = rules.first(where: { $0.id == id }) else {
      return false
    }
    rule.isEnabled = enabled
    return await save(rule)
  }

  public func reset() async {
    do {
      try await repository.resetReplacementRules()
      await reload()
    } catch {
      errorMessage = "无法重置替换规则"
    }
  }

  public var nextOrder: Int {
    (rules.map(\.order).max() ?? -1) + 1
  }
}
