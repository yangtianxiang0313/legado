import AndroidBackupInterop
import AppUseCases

public enum AndroidReplaceRuleInteropError: Error, Equatable, Sendable {
  case orderOutOfRange(Int)
}

public enum AndroidReplaceRuleInteropAdapter {
  public static func backupDocuments(
    _ values: [ReaderReplacementRule]
  ) throws -> [AndroidReplaceRuleDTO] {
    try values.map { value in
      guard let order = Int32(exactly: value.order) else {
        throw AndroidReplaceRuleInteropError.orderOutOfRange(value.order)
      }
      return AndroidReplaceRuleDTO(
        id: Int64(value.id) ?? stableAndroidID(value.id),
        name: value.name,
        pattern: value.pattern,
        replacement: value.replacement,
        scope: value.scope,
        scopeTitle: value.appliesToTitle,
        scopeContent: value.appliesToContent,
        excludeScope: value.excludeScope,
        isEnabled: value.isEnabled,
        isRegex: value.isRegex,
        order: order
      )
    }
  }

  private static func stableAndroidID(_ value: String) -> Int64 {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in value.utf8 {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    let positive = hash & UInt64(Int64.max)
    return positive == 0 ? 1 : Int64(positive)
  }
}
