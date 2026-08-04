import AndroidBackupInterop
import AppUseCases
import Foundation
import LibraryDomain

public enum AndroidReplacementRuleInteropAdapter {
  public static func restoreValues(
    _ documents: [AndroidReplaceRuleDTO]
  ) throws -> [ReaderReplacementRule] {
    try documents.map(restoreValue)
  }

  public static func restoreValue(
    _ value: AndroidReplaceRuleDTO
  ) throws -> ReaderReplacementRule {
    let projection = value.restoreProjection
    guard let order = Int(exactly: projection.order) else {
      throw AndroidLibraryImportError.integerOutOfRange(
        field: "replaceRule.order",
        value: projection.order
      )
    }
    return ReaderReplacementRule(
      id: String(projection.id),
      name: projection.name,
      pattern: projection.pattern,
      replacement: projection.replacement,
      scope: projection.scope,
      excludeScope: projection.excludeScope,
      appliesToTitle: projection.scopeTitle,
      appliesToContent: projection.scopeContent,
      isEnabled: projection.isEnabled,
      isRegex: projection.isRegex,
      order: order
    )
  }
}

public enum AndroidRuleSubscriptionPayloadImport {
  public static func decodeRSSSources(_ data: Data) throws -> [RSSSource] {
    AndroidRSSInteropAdapter.restoreSources(
      try AndroidRSSCodec.decodeSources(data)
    )
  }

  public static func decodeReplacementRules(
    _ data: Data
  ) throws -> [ReaderReplacementRule] {
    try AndroidReplacementRuleInteropAdapter.restoreValues(
      AndroidReplaceRuleCodec.decodeMany(data)
    )
  }
}

public enum AndroidOnlineImportPayloadImport {
  public static func decodeHTTPTextToSpeechEngines(
    _ data: Data
  ) throws -> [HTTPTextToSpeechEngine] {
    AndroidHTTPTextToSpeechInteropAdapter.restoreValues(
      try AndroidHTTPTextToSpeechCodec.decodeMany(data)
    )
  }

  public static func decodeDictionaryRules(
    _ data: Data
  ) throws -> [DictionaryRule] {
    AndroidDictionaryRuleInteropAdapter.restoreValues(
      try AndroidDictionaryRuleCodec.decodeMany(data)
    )
  }

  public static func decodeLocalTextTOCRules(
    _ data: Data
  ) throws -> [LocalTextTOCRule] {
    AndroidLocalTextTOCRuleInteropAdapter.restoreValues(
      try AndroidLocalTextTOCRuleCodec.decodeMany(data)
    )
  }

  public static func decodeThemeProfiles(_ data: Data) throws
    -> [AppThemeProfile]
  {
    AndroidThemeConfigInteropAdapter.restoreValues(
      try AndroidThemeConfigCodec.decodeMany(data)
    )
  }
}
