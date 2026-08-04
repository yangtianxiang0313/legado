import BackupInteropUseCases
import Foundation
import Testing

@Suite("Android online import link")
struct AndroidOnlineImportLinkTests {
  @Test(arguments: [
    ("legado://import/bookSource?src=https%3A%2F%2Fexample.test%2Fbook.json", AndroidOnlineImportTarget.bookSource),
    ("yuedu://import/rssSource?src=https%3A%2F%2Fexample.test%2Frss.json", AndroidOnlineImportTarget.rssSource),
    ("legado://import/replaceRule?src=https%3A%2F%2Fexample.test%2Frules.json", AndroidOnlineImportTarget.replaceRule),
    ("legado://booksource/importonline?src=https%3A%2F%2Fexample.test%2Fbook.json", AndroidOnlineImportTarget.bookSource),
  ])
  func parsesAndroidCompatibleLink(
    value: (String, AndroidOnlineImportTarget)
  ) throws {
    let request = try AndroidOnlineImportLinkParser.parse(
      try #require(URL(string: value.0))
    )
    #expect(request.target == value.1)
    #expect(request.sourceURL.hasPrefix("https://example.test/"))
  }

  @Test func rejectsUnsupportedAndroidTarget() throws {
    let url = try #require(URL(
      string: "legado://import/httpTTS?src=https%3A%2F%2Fexample.test%2Ftts.json"
    ))
    #expect(throws: AndroidOnlineImportLinkError.unsupportedTarget) {
      try AndroidOnlineImportLinkParser.parse(url)
    }
  }

  @Test func requiresSourceURL() throws {
    let url = try #require(URL(string: "legado://import/bookSource"))
    #expect(throws: AndroidOnlineImportLinkError.missingSourceURL) {
      try AndroidOnlineImportLinkParser.parse(url)
    }
  }
}
