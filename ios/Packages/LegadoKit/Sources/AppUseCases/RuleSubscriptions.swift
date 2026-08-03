import Foundation
import Observation

public struct RuleSubscription: Identifiable, Equatable, Sendable {
  public let id: Int64
  public var name: String
  public var url: String
  public var type: Int
  public var customOrder: Int
  public var autoUpdate: Bool
  public var updatedAt: Int64

  public init(
    id: Int64,
    name: String,
    url: String,
    type: Int,
    customOrder: Int,
    autoUpdate: Bool,
    updatedAt: Int64
  ) {
    self.id = id
    self.name = name
    self.url = url
    self.type = type
    self.customOrder = customOrder
    self.autoUpdate = autoUpdate
    self.updatedAt = updatedAt
  }
}

public protocol RuleSubscriptionRepository: Sendable {
  func ruleSubscriptions() async throws -> [RuleSubscription]
  func upsertRuleSubscription(_ value: RuleSubscription) async throws
  func deleteRuleSubscription(id: Int64) async throws
}

@MainActor
@Observable
public final class RuleSubscriptionStore {
  public private(set) var subscriptions: [RuleSubscription] = []
  public private(set) var errorMessage: String?

  private let repository: any RuleSubscriptionRepository

  public init(repository: any RuleSubscriptionRepository) {
    self.repository = repository
  }

  public func reload() async {
    do {
      subscriptions = try await repository.ruleSubscriptions()
      errorMessage = nil
    } catch {
      errorMessage = "无法读取规则订阅"
    }
  }

  @discardableResult
  public func save(_ value: RuleSubscription) async -> Bool {
    let normalizedURL = value.url.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedURL.isEmpty else {
      errorMessage = "订阅地址不能为空"
      return false
    }
    if subscriptions.contains(where: {
      $0.id != value.id && $0.url == normalizedURL
    }) {
      errorMessage = "订阅地址已存在"
      return false
    }
    do {
      var normalized = value
      normalized.url = normalizedURL
      try await repository.upsertRuleSubscription(normalized)
      await reload()
      return true
    } catch {
      errorMessage = "无法保存规则订阅"
      return false
    }
  }

  public func remove(id: Int64) async {
    do {
      try await repository.deleteRuleSubscription(id: id)
      await reload()
    } catch {
      errorMessage = "无法删除规则订阅"
    }
  }
}
