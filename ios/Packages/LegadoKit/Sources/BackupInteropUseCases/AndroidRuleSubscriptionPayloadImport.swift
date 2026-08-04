import AndroidBackupInterop
import AppUseCases
import Foundation

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
