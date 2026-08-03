import AndroidBackupInterop
import AppUseCases
import LegadoCore

public enum AndroidDictionaryRuleInteropAdapter {
  public static func restoreValues(_ documents: [AndroidDictionaryRuleDTO])
    -> [DictionaryRule]
  {
    documents.map {
      DictionaryRule(
        name: $0.string("name") ?? "",
        urlRule: $0.string("urlRule") ?? "",
        showRule: $0.string("showRule") ?? "",
        isEnabled: $0.boolean("enabled") ?? true,
        sortNumber: Int(exactly: $0.integer("sortNumber") ?? 0) ?? 0
      )
    }
  }

  public static func backupDocuments(_ values: [DictionaryRule])
    -> [AndroidDictionaryRuleDTO]
  {
    values.map {
      AndroidDictionaryRuleDTO(values: [
        "name": .string($0.name),
        "urlRule": .string($0.urlRule),
        "showRule": .string($0.showRule),
        "enabled": .bool($0.isEnabled),
        "sortNumber": .number(JSONNumber(Int64($0.sortNumber))),
      ])
    }
  }
}
