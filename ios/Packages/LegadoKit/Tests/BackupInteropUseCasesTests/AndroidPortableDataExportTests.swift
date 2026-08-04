import AndroidBackupInterop
import AppUseCases
import BackupInteropUseCases
import LibraryDomain
import Testing

@Suite("Android portable data export")
struct AndroidPortableDataExportTests {
  @Test func exportsEveryRuleDomainWithAndroidFilenamesAndCodecs() throws {
    let files = try [
      AndroidPortableDataExport.rssSources([
        RSSSource(
          sourceURL: "https://rss.example/feed",
          sourceName: "新闻",
          sourceGroup: "资讯",
          ruleTitle: "$.title"
        ),
      ]),
      AndroidPortableDataExport.replacementRules([
        ReaderReplacementRule(
          id: "ios-rule",
          name: "去广告",
          pattern: "广告",
          replacement: "",
          appliesToTitle: true,
          order: 7
        ),
      ]),
      AndroidPortableDataExport.httpTextToSpeech([
        HTTPTextToSpeechEngine(
          id: 9,
          name: "在线女声",
          url: "https://tts.example/{{speakText}}",
          contentType: "audio/mpeg"
        ),
      ]),
      AndroidPortableDataExport.dictionaryRules([
        DictionaryRule(
          name: "汉典",
          urlRule: "https://dict.example/{{key}}",
          showRule: "$.body",
          sortNumber: 2
        ),
      ]),
      AndroidPortableDataExport.localTextTOCRules([
        LocalTextTOCRule(
          id: 3,
          name: "章节",
          rule: "^第.+章$",
          serialNumber: 4
        ),
      ]),
      AndroidPortableDataExport.themes([
        AppThemeProfile(
          name: "深夜",
          isNightTheme: true,
          primaryColor: "#101010",
          accentColor: "#ff8800",
          backgroundColor: "#000000",
          bottomBackgroundColor: "#080808"
        ),
      ]),
    ]

    #expect(files.map(\.filename) == [
      "exportRssSource.json",
      "exportReplaceRule.json",
      "httpTts.json",
      "exportDictRule.json",
      "exportTxtTocRule.json",
      "themeConfig.json",
    ])
    #expect(try AndroidRSSCodec.decodeSources(files[0].data).first?
      .string("sourceName") == "新闻")
    #expect(try AndroidReplaceRuleCodec.decodeMany(files[1].data).first?
      .restoreProjection.order == 7)
    #expect(try AndroidHTTPTextToSpeechCodec.decodeMany(files[2].data).first?
      .string("contentType") == "audio/mpeg")
    #expect(try AndroidDictionaryRuleCodec.decodeMany(files[3].data).first?
      .integer("sortNumber") == 2)
    #expect(try AndroidLocalTextTOCRuleCodec.decodeMany(files[4].data).first?
      .string("rule") == "^第.+章$")
    #expect(try AndroidThemeConfigCodec.decodeMany(files[5].data).first?
      .boolean("isNightTheme") == true)

    let expectedTargets: [AndroidOnlineImportTarget] = [
      .rssSource, .replaceRule, .httpTTS, .dictionaryRule,
      .localTextTOCRule, .theme,
    ]
    #expect(try files.map {
      try AndroidAssociatedImportClassifier.classifyJSON($0.data)
    } == expectedTargets)
  }

  @Test func refusesReplacementOrderThatAndroidCannotRepresent() {
    let rule = ReaderReplacementRule(
      name: "越界",
      pattern: "x",
      replacement: "",
      order: Int(Int32.max) + 1
    )
    #expect(throws: AndroidReplaceRuleInteropError.orderOutOfRange(rule.order)) {
      try AndroidPortableDataExport.replacementRules([rule])
    }
  }
}
