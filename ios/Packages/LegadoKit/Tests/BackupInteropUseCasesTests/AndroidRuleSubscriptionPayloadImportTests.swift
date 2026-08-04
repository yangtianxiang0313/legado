import BackupInteropUseCases
import Foundation
import Testing

@Suite("Android rule subscription payload import")
struct AndroidRuleSubscriptionPayloadImportTests {
  @Test func decodesRSSSubscriptionPayload() throws {
    let values = try AndroidRuleSubscriptionPayloadImport.decodeRSSSources(
      Data(
        #"[{"sourceUrl":"https://rss.example/feed","sourceName":"示例 RSS","enabled":false,"ruleArticles":"$.items[*]","customOrder":7}]"#.utf8
      )
    )

    let value = try #require(values.first)
    #expect(values.count == 1)
    #expect(value.sourceURL == "https://rss.example/feed")
    #expect(value.sourceName == "示例 RSS")
    #expect(value.enabled == false)
    #expect(value.ruleArticles == "$.items[*]")
    #expect(value.customOrder == 7)
  }

  @Test func decodesReplacementRuleSubscriptionPayload() throws {
    let values = try AndroidRuleSubscriptionPayloadImport
      .decodeReplacementRules(
        Data(
          #"[{"id":42,"name":"去广告","pattern":"ad+","replacement":"","scopeTitle":true,"scopeContent":false,"isEnabled":true,"isRegex":true,"order":3}]"#.utf8
        )
      )

    let value = try #require(values.first)
    #expect(values.count == 1)
    #expect(value.id == "42")
    #expect(value.name == "去广告")
    #expect(value.pattern == "ad+")
    #expect(value.appliesToTitle)
    #expect(value.appliesToContent == false)
    #expect(value.order == 3)
  }
}
