import AndroidBackupInterop
import LegadoCore
import LibraryDomain

public enum AndroidLocalTextTOCRuleInteropAdapter {
  public static func restoreValues(
    _ documents: [AndroidLocalTextTOCRuleDTO]
  ) -> [LocalTextTOCRule] {
    documents.map {
      LocalTextTOCRule(
        id: $0.integer("id") ?? 0,
        name: $0.string("name") ?? "",
        rule: $0.string("rule") ?? "",
        example: $0.string("example"),
        serialNumber: Int(exactly: $0.integer("serialNumber") ?? -1) ?? -1,
        isEnabled: $0.boolean("enable") ?? true
      )
    }
  }

  public static func backupDocuments(
    _ values: [LocalTextTOCRule]
  ) -> [AndroidLocalTextTOCRuleDTO] {
    values.map {
      AndroidLocalTextTOCRuleDTO(values: [
        "id": .number(JSONNumber($0.id)),
        "name": .string($0.name),
        "rule": .string($0.rule),
        "example": $0.example.map(JSONValue.string),
        "serialNumber": .number(JSONNumber(Int64($0.serialNumber))),
        "enable": .bool($0.isEnabled),
      ])
    }
  }
}
