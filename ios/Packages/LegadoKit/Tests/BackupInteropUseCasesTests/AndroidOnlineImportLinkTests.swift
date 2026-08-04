import BackupInteropUseCases
import ArchiveZIPFoundation
import Foundation
import LibraryDomain
import Testing

@Suite("Android online import link")
struct AndroidOnlineImportLinkTests {
  @Test(arguments: [
    ("legado://import/bookSource?src=https%3A%2F%2Fexample.test%2Fbook.json", AndroidOnlineImportTarget.bookSource),
    ("yuedu://import/rssSource?src=https%3A%2F%2Fexample.test%2Frss.json", AndroidOnlineImportTarget.rssSource),
    ("legado://import/replaceRule?src=https%3A%2F%2Fexample.test%2Frules.json", AndroidOnlineImportTarget.replaceRule),
    ("legado://import/httpTTS?src=https%3A%2F%2Fexample.test%2Ftts.json", AndroidOnlineImportTarget.httpTTS),
    ("legado://import/dictRule?src=https%3A%2F%2Fexample.test%2Fdict.json", AndroidOnlineImportTarget.dictionaryRule),
    ("yuedu://import/textTocRule?src=https%3A%2F%2Fexample.test%2Ftoc.json", AndroidOnlineImportTarget.localTextTOCRule),
    ("legado://import/addToBookshelf?src=https%3A%2F%2Fbooks.example%2Fnovel%2F1", AndroidOnlineImportTarget.addToBookshelf),
    ("legado://import/readConfig?src=https%3A%2F%2Fexample.test%2Freader.zip", AndroidOnlineImportTarget.readerConfig),
    ("legado://import/theme?src=https%3A%2F%2Fexample.test%2Ftheme.json", AndroidOnlineImportTarget.theme),
    ("legado://booksource/importonline?src=https%3A%2F%2Fexample.test%2Fbook.json", AndroidOnlineImportTarget.bookSource),
  ])
  func parsesAndroidCompatibleLink(
    value: (String, AndroidOnlineImportTarget)
  ) throws {
    let request = try AndroidOnlineImportLinkParser.parse(
      try #require(URL(string: value.0))
    )
    #expect(request.target == value.1)
    #expect(request.sourceURL.hasPrefix("https://"))
  }

  @Test func rejectsUnsupportedAndroidTarget() throws {
    let url = try #require(URL(
      string: "legado://import/unknown?src=https%3A%2F%2Fexample.test%2Funknown.json"
    ))
    #expect(throws: AndroidOnlineImportLinkError.unsupportedTarget) {
      try AndroidOnlineImportLinkParser.parse(url)
    }
  }

  @Test func decodesThemePayload() throws {
    let values = try AndroidOnlineImportPayloadImport.decodeThemeProfiles(
      Data(##"[{"themeName":"深夜","isNightTheme":true,"primaryColor":"#101010","accentColor":"#ff8800","backgroundColor":"#000000","bottomBackground":"#080808"}]"##.utf8)
    )
    #expect(values.first?.name == "深夜")
    #expect(values.first?.isNightTheme == true)
    #expect(values.first?.accentColor == "#ff8800")
  }

  @Test func decodesDictionaryAndLocalTOCPayloads() throws {
    let dictionaries = try AndroidOnlineImportPayloadImport
      .decodeDictionaryRules(Data(
        #"[{"name":"汉典","urlRule":"https://dict.example/{{key}}","showRule":"$.body","enabled":true,"sortNumber":2}]"#.utf8
      ))
    #expect(dictionaries.first?.name == "汉典")
    #expect(dictionaries.first?.sortNumber == 2)

    let tocRules = try AndroidOnlineImportPayloadImport
      .decodeLocalTextTOCRules(Data(
        #"[{"id":9,"name":"章节","rule":"^第.+章$","serialNumber":3,"enable":true}]"#.utf8
      ))
    #expect(tocRules.first?.id == 9)
    #expect(tocRules.first?.rule == "^第.+章$")
  }

  @Test func decodesReaderConfigArchiveAndResources() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString + ".zip")
    defer { try? FileManager.default.removeItem(at: url) }
    try ArchiveZIPFoundation.create(members: [
      .init(
        path: "readConfig.json",
        data: Data(#"{"name":"纸张","textSize":21,"lineSpacingExtra":9,"textFont":"custom.ttf"}"#.utf8)
      ),
      .init(path: "custom.ttf", data: Data([0, 1, 2, 3])),
    ], at: url)

    let payload = try AndroidReaderConfigArchiveImport.decode(from: url)
    #expect(payload.name == "纸张")
    #expect(payload.projection?.fontSize == 21)
    #expect(payload.projection?.lineSpacing == 9)
    #expect(payload.resources["custom.ttf"] == Data([0, 1, 2, 3]))
  }

  @Test func decodesHTTPTextToSpeechPayload() throws {
    let values = try AndroidOnlineImportPayloadImport
      .decodeHTTPTextToSpeechEngines(Data(
        #"[{"id":17,"name":"在线女声","url":"https://tts.example/{{speakText}}","contentType":"audio/mpeg","enabledCookieJar":true}]"#.utf8
      ))
    let value = try #require(values.first)
    #expect(value.id == 17)
    #expect(value.name == "在线女声")
    #expect(value.contentType == "audio/mpeg")
    #expect(value.enabledCookieJar == true)
  }

  @Test func requiresSourceURL() throws {
    let url = try #require(URL(string: "legado://import/bookSource"))
    #expect(throws: AndroidOnlineImportLinkError.missingSourceURL) {
      try AndroidOnlineImportLinkParser.parse(url)
    }
  }
}
