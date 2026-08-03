import AndroidBackupInterop
import AppUseCases
import BackupInteropUseCases
import DatabaseGRDB
import Foundation
import LegadoCore
import Testing

@Suite("RSSInteropTests")
struct RSSInteropTests {
  @Test func preservesRSSFieldsAndCompositeStarIdentity() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try GRDBBookShelfRepository(
      path: directory.appendingPathComponent("library.sqlite").path
    )
    let source = RSSSource(
      sourceURL: "https://example.test/rss",
      sourceName: "示例 RSS",
      sourceIcon: "https://example.test/icon.png",
      sourceGroup: "技术",
      sourceComment: "完整字段",
      enabled: true,
      variableComment: "变量",
      jsLib: "lib.js",
      enabledCookieJar: false,
      concurrentRate: "2/1000",
      header: "{\"User-Agent\":\"Legado\"}",
      loginURL: "https://example.test/login",
      loginUI: "{}",
      loginCheckJS: "true",
      coverDecodeJS: "result",
      sortURL: "https://example.test/sort",
      singleURL: false,
      articleStyle: 2,
      ruleArticles: "article",
      ruleNextPage: "next",
      ruleTitle: "title",
      rulePubDate: "date",
      ruleDescription: "description",
      ruleImage: "image",
      ruleLink: "link",
      ruleContent: "content",
      contentWhitelist: "allow",
      contentBlacklist: "deny",
      shouldOverrideURLLoading: "false",
      style: "body{}",
      enableJS: true,
      loadWithBaseURL: false,
      injectJS: "inject()",
      lastUpdateTime: 9_000,
      customOrder: 3
    )
    let star = RSSStar(
      origin: source.sourceURL,
      sort: "技术",
      title: "文章",
      starTime: 10_000,
      link: "https://example.test/article",
      pubDate: "2026-08-03",
      description: "摘要",
      content: "正文",
      image: "cover.png",
      variable: "{\"key\":\"value\"}"
    )

    let sourceDocuments = AndroidRSSInteropAdapter.backupSources([source])
    let starDocuments = AndroidRSSInteropAdapter.backupStars([star])
    #expect(AndroidRSSInteropAdapter.restoreSources(sourceDocuments) == [source])
    #expect(AndroidRSSInteropAdapter.restoreStars(starDocuments) == [star])

    let archiveURL = directory.appendingPathComponent("backup.zip")
    try AndroidBackupArchive.write(
      AndroidBackupContents(
        rssSources: sourceDocuments,
        rssStars: starDocuments
      ),
      to: archiveURL
    )
    #expect(try AndroidBackupArchive.readRSSSources(from: archiveURL) == sourceDocuments)
    #expect(try AndroidBackupArchive.readRSSStars(from: archiveURL) == starDocuments)

    try await repository.restoreAndroidRSS(sources: [source], stars: [star])
    #expect(try await repository.rssSources() == [source])
    #expect(try await repository.rssStars() == [star])
  }
}
