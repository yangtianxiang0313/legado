import AndroidBackupInterop
import AppUseCases
import LegadoCore

public enum AndroidKeyboardAssistInteropAdapter {
  public static func restoreValues(_ documents: [AndroidKeyboardAssistDTO])
    -> [KeyboardAssist]
  {
    documents.map { document in
      KeyboardAssist(
        type: Int(exactly: document.integer("type") ?? 0) ?? 0,
        key: document.string("key") ?? "",
        value: document.string("value") ?? "",
        serialNumber: Int(exactly: document.integer("serialNo") ?? 0) ?? 0,
        unknownFields: document.rawFields.filter {
          !AndroidKeyboardAssistDTO.knownFieldNames.contains($0.key)
        }
      )
    }
  }

  public static func backupDocuments(_ values: [KeyboardAssist])
    -> [AndroidKeyboardAssistDTO]
  {
    values.map {
      AndroidKeyboardAssistDTO(
        values: [
          "type": .number(JSONNumber(Int64($0.type))),
          "key": .string($0.key),
          "value": .string($0.value),
          "serialNo": .number(JSONNumber(Int64($0.serialNumber))),
        ],
        unknownFields: $0.unknownFields
      )
    }
  }
}
