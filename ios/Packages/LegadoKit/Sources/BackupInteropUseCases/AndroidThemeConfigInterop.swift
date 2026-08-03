import AndroidBackupInterop
import AppUseCases
import LegadoCore

public enum AndroidThemeConfigInteropAdapter {
  public static func restoreValues(_ documents: [AndroidThemeConfigDTO])
    -> [AppThemeProfile]
  {
    documents.map { document in
      AppThemeProfile(
        name: document.string("themeName") ?? "",
        isNightTheme: document.boolean("isNightTheme") ?? false,
        primaryColor: document.string("primaryColor") ?? "",
        accentColor: document.string("accentColor") ?? "",
        backgroundColor: document.string("backgroundColor") ?? "",
        bottomBackgroundColor: document.string("bottomBackground") ?? "",
        unknownFields: document.rawFields.filter {
          !AndroidThemeConfigDTO.knownFieldNames.contains($0.key)
        }
      )
    }
  }

  public static func backupDocuments(_ values: [AppThemeProfile])
    -> [AndroidThemeConfigDTO]
  {
    values.map {
      AndroidThemeConfigDTO(
        values: [
          "themeName": .string($0.name),
          "isNightTheme": .bool($0.isNightTheme),
          "primaryColor": .string($0.primaryColor),
          "accentColor": .string($0.accentColor),
          "backgroundColor": .string($0.backgroundColor),
          "bottomBackground": .string($0.bottomBackgroundColor),
        ],
        unknownFields: $0.unknownFields
      )
    }
  }
}
