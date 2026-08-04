import AndroidBackupInterop
import AppUseCases
import Foundation
import LibraryDomain

public enum AndroidPortableExportKind: String, CaseIterable, Sendable {
  case rssSources
  case replacementRules
  case httpTextToSpeech
  case dictionaryRules
  case localTextTOCRules
  case themes

  public var filename: String {
    switch self {
    case .rssSources: "exportRssSource.json"
    case .replacementRules: "exportReplaceRule.json"
    case .httpTextToSpeech: "httpTts.json"
    case .dictionaryRules: "exportDictRule.json"
    case .localTextTOCRules: "exportTxtTocRule.json"
    case .themes: "themeConfig.json"
    }
  }
}

public struct AndroidPortableExportFile: Equatable, Sendable {
  public let kind: AndroidPortableExportKind
  public let data: Data

  public init(kind: AndroidPortableExportKind, data: Data) {
    self.kind = kind
    self.data = data
  }

  public var filename: String { kind.filename }
}

public enum AndroidPortableDataExport {
  public static func rssSources(_ values: [RSSSource]) throws
    -> AndroidPortableExportFile
  {
    AndroidPortableExportFile(
      kind: .rssSources,
      data: try AndroidRSSCodec.encodeSources(
        AndroidRSSInteropAdapter.backupSources(values)
      )
    )
  }

  public static func replacementRules(_ values: [ReaderReplacementRule]) throws
    -> AndroidPortableExportFile
  {
    AndroidPortableExportFile(
      kind: .replacementRules,
      data: try AndroidReplaceRuleCodec.encodeMany(
        AndroidReplaceRuleInteropAdapter.backupDocuments(values)
      )
    )
  }

  public static func httpTextToSpeech(
    _ values: [HTTPTextToSpeechEngine]
  ) throws -> AndroidPortableExportFile {
    AndroidPortableExportFile(
      kind: .httpTextToSpeech,
      data: try AndroidHTTPTextToSpeechCodec.encodeMany(
        AndroidHTTPTextToSpeechInteropAdapter.backupDocuments(values)
      )
    )
  }

  public static func dictionaryRules(_ values: [DictionaryRule]) throws
    -> AndroidPortableExportFile
  {
    AndroidPortableExportFile(
      kind: .dictionaryRules,
      data: try AndroidDictionaryRuleCodec.encodeMany(
        AndroidDictionaryRuleInteropAdapter.backupDocuments(values)
      )
    )
  }

  public static func localTextTOCRules(_ values: [LocalTextTOCRule]) throws
    -> AndroidPortableExportFile
  {
    AndroidPortableExportFile(
      kind: .localTextTOCRules,
      data: try AndroidLocalTextTOCRuleCodec.encodeMany(
        AndroidLocalTextTOCRuleInteropAdapter.backupDocuments(values)
      )
    )
  }

  public static func themes(_ values: [AppThemeProfile]) throws
    -> AndroidPortableExportFile
  {
    AndroidPortableExportFile(
      kind: .themes,
      data: try AndroidThemeConfigCodec.encodeMany(
        AndroidThemeConfigInteropAdapter.backupDocuments(values)
      )
    )
  }
}
