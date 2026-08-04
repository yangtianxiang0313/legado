import AndroidBackupInterop
import AppUseCases
import Foundation

public enum AndroidDirectLinkUploadRuleExchange {
  public static let filename = "directLinkUploadRule.json"

  public static func decode(_ data: Data) throws -> DirectLinkUploadRule {
    AndroidDirectLinkUploadRuleInteropAdapter.restoreValue(
      try AndroidDirectLinkUploadRuleCodec.decode(data)
    )!
  }

  public static func encode(_ value: DirectLinkUploadRule) throws -> Data {
    try AndroidDirectLinkUploadRuleCodec.encode(
      AndroidDirectLinkUploadRuleInteropAdapter.backupDocument(value)!
    )
  }
}
