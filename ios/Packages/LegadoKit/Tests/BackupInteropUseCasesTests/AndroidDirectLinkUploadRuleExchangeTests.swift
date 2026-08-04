import BackupInteropUseCases
import Foundation
import LegadoCore
import Testing

@Suite("Android direct-link upload rule exchange")
struct AndroidDirectLinkUploadRuleExchangeTests {
  @Test func preservesAndroidFieldsAndUnknownExtensions() throws {
    let data = Data(
      #"{"uploadUrl":"https://upload.example/{{fileName}}","downloadUrlRule":"$.url","summary":"对象存储","compress":true,"vendor":"keep"}"#.utf8
    )
    let rule = try AndroidDirectLinkUploadRuleExchange.decode(data)
    #expect(rule.summary == "对象存储")
    #expect(rule.compress)
    #expect(rule.unknownFields["vendor"] == .string("keep"))

    let encoded = try AndroidDirectLinkUploadRuleExchange.encode(rule)
    #expect(try AndroidDirectLinkUploadRuleExchange.decode(encoded) == rule)
    #expect(try AndroidAssociatedImportClassifier.classifyJSON(encoded)
      == .directLinkUploadRule)
  }
}
