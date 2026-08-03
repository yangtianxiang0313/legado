import AndroidBackupInterop
import AppUseCases

public enum AndroidRuleSubscriptionInteropAdapter {
  public static func restoreValues(
    _ documents: [AndroidRuleSubscriptionDTO]
  ) -> [RuleSubscription] {
    documents.map {
      RuleSubscription(
        id: $0.id,
        name: $0.name,
        url: $0.url,
        type: $0.type,
        customOrder: $0.customOrder,
        autoUpdate: $0.autoUpdate,
        updatedAt: $0.updatedAt
      )
    }
  }

  public static func backupDocuments(
    _ values: [RuleSubscription]
  ) -> [AndroidRuleSubscriptionDTO] {
    values.map {
      AndroidRuleSubscriptionDTO(
        id: $0.id,
        name: $0.name,
        url: $0.url,
        type: $0.type,
        customOrder: $0.customOrder,
        autoUpdate: $0.autoUpdate,
        updatedAt: $0.updatedAt
      )
    }
  }
}
