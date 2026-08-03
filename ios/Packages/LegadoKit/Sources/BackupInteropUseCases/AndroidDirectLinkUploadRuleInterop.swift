import AndroidBackupInterop
import AppUseCases
import LegadoCore

public enum AndroidDirectLinkUploadRuleInteropAdapter {
  public static func restoreValue(
    _ document: AndroidDirectLinkUploadRuleDTO?
  ) -> DirectLinkUploadRule? {
    guard let document else { return nil }
    return DirectLinkUploadRule(
      uploadURL: string(document.rawFields["uploadUrl"]),
      downloadURLRule: string(document.rawFields["downloadUrlRule"]),
      summary: string(document.rawFields["summary"]),
      compress: boolean(document.rawFields["compress"]),
      unknownFields: document.unknownFields
    )
  }

  public static func backupDocument(
    _ value: DirectLinkUploadRule?
  ) -> AndroidDirectLinkUploadRuleDTO? {
    guard let value else { return nil }
    return AndroidDirectLinkUploadRuleDTO(
      values: [
        "uploadUrl": .string(value.uploadURL),
        "downloadUrlRule": .string(value.downloadURLRule),
        "summary": .string(value.summary),
        "compress": .bool(value.compress),
      ],
      unknownFields: value.unknownFields
    )
  }

  private static func string(_ value: JSONValue?) -> String {
    guard case .string(let result) = value else { return "" }
    return result
  }

  private static func boolean(_ value: JSONValue?) -> Bool {
    guard case .bool(let result) = value else { return false }
    return result
  }
}
