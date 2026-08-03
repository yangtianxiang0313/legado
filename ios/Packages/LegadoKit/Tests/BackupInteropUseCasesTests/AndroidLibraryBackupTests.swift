import AndroidBackupInterop
import AppUseCases
import BackupInteropUseCases
import Foundation
import LibraryDomain
import Testing

@Suite("AndroidLibraryBackupUseCaseTests")
struct AndroidLibraryBackupUseCaseTests {
  @Test func writesArchiveThatImportsBackToTheSameLibraryPlan() async throws {
    let plan = fixturePlan()
    let repository = BackupRepositoryStub(
      plan: plan,
      records: [
        ReadRecord(
          deviceID: "ios-device",
          bookName: "iOS Book",
          readTime: 7_200,
          lastRead: 1_700_000_000_987
        )
      ],
      tocRules: [
        LocalTextTOCRule(
          id: 7,
          name: "卷章",
          rule: "^卷.+$",
          serialNumber: 1
        )
      ],
      readerConfig: try AndroidReaderConfigBundle(
        stylesData: Data(#"[{"name":"paper","textSize":18}]"#.utf8),
        sharedStyleData: Data(
          #"{"name":"shared","textSize":26,"lineSpacingExtra":12}"#.utf8
        )
      ),
      dictionaryRules: [
        DictionaryRule(
          name: "词典",
          urlRule: "https://dict.invalid/{{key}}",
          sortNumber: 2
        )
      ]
    )
    let useCase = AndroidLibraryBackupUseCase(repository: repository)
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let archiveURL = directory.appendingPathComponent("backup.zip")

    let summary = try await useCase.export(
      to: archiveURL,
      bookSources: [
        BookSourceDraft(
          sourceURL: "https://ios.invalid/source",
          name: "iOS Source",
          searchURL: "https://ios.invalid/search?key={{key}}",
          searchRule: "$.books[*]"
        )
      ],
      replacementRules: [
        ReaderReplacementRule(
          id: "ios-rule",
          name: "去广告",
          pattern: "ad",
          replacement: "",
          order: 3
        )
      ],
      readerPreferences: nil,
      applicationPreferences: AndroidApplicationBackupExportInput(
        showsDiscovery: false,
        showsRSS: true,
        bookshelfSort: .combinedTime
      ),
      webDAVConfiguration: nil
    )
    let restored = try AndroidLibraryImportAdapter.plan(from: archiveURL)
    let sources = try AndroidBackupArchive.readBookSources(from: archiveURL)
    let rules = try AndroidBackupArchive.readReplacementRules(from: archiveURL)
    let records = try AndroidBackupArchive.readReadRecords(from: archiveURL)
    let tocRules = try AndroidBackupArchive.readLocalTextTOCRules(
      from: archiveURL
    )
    let readerConfigs = try AndroidBackupArchive.readReaderConfigs(
      from: archiveURL
    )
    let sharedReaderConfig = try AndroidBackupArchive.readSharedReaderConfig(
      from: archiveURL
    )
    let dictionaryRules = try AndroidBackupArchive.readDictionaryRules(
      from: archiveURL
    )
    let sharedPreferencesDocument = try AndroidBackupArchive
      .readSharedPreferences(from: archiveURL)
    let sharedPreferences = AndroidApplicationBackupPreferences(
      document: try #require(sharedPreferencesDocument)
    )

    #expect(
      summary == AndroidLibraryBackupSummary(
        bookCount: 1,
        groupCount: 1,
        bookmarkCount: 1,
        bookSourceCount: 1,
        replacementRuleCount: 1,
        readRecordCount: 1,
        localTextTOCRuleCount: 1,
        readerConfigCount: 2,
        dictionaryRuleCount: 1
      )
    )
    #expect(restored == plan)
    #expect(sources.first?.bookSourceUrl == .value("https://ios.invalid/source"))
    #expect(rules.first?.name == .value("去广告"))
    #expect(rules.first?.order == .value(3))
    #expect(records.first?.restoreProjection.deviceID == "ios-device")
    #expect(records.first?.restoreProjection.readTime == 7_200)
    #expect(tocRules.first?.string("name") == "卷章")
    #expect(readerConfigs.first?.integer("textSize") == 18)
    #expect(sharedReaderConfig?.integer("textSize") == 26)
    #expect(dictionaryRules.first?.string("name") == "词典")
    #expect(
      sharedPreferences.showsDiscovery == false
    )
    #expect(
      sharedPreferences.showsRSS == true
    )
    #expect(
      sharedPreferences.bookshelfSort == 4
    )
  }

  private func fixturePlan() -> AndroidLibraryRestorePlan {
    AndroidLibraryRestorePlan(
      books: [
        AndroidLibraryRestoreBook(
          candidate: ShelfBookCandidate(
            name: "iOS Book",
            author: "iOS Author",
            kind: "fiction",
            lastChapter: "Chapter Ten",
            intro: "intro",
            bookURL: "https://ios.invalid/book",
            tocURL: "https://ios.invalid/toc",
            coverURL: "https://ios.invalid/cover",
            customIntro: "custom intro",
            originName: "iOS Source",
            sourceID: "https://ios.invalid/source",
            variables: ["token": "kept"]
          ),
          groupMask: 9,
          order: 6,
          chapterCount: 10,
          progress: ReadingProgress(
            position: ReadingPosition(chapterIndex: 3, characterOffset: 27),
            chapterTitle: "Chapter Four",
            updatedAtMilliseconds: 1_700_000_000_123
          ),
          latestChapterTime: 1_700_000_000_000,
          lastCheckTime: 1_700_000_000_100,
          latestCheckCount: 2,
          canUpdate: false,
          reversesTableOfContents: true,
          splitsLongChapters: false,
          androidType: 1,
          originOrder: 2,
          syncTime: 1_700_000_000_999,
          charset: "GBK",
          customTag: "favorite",
          wordCount: "10000"
        )
      ],
      groups: [
        AndroidLibraryRestoreGroup(
          id: 8,
          name: "工作",
          cover: "group-cover",
          order: 4,
          enablesRefresh: false,
          isShown: true,
          bookSort: 2
        )
      ],
      bookmarks: [
        Bookmark(
          time: 1_700_000_000_123,
          bookName: "iOS Book",
          bookAuthor: "iOS Author",
          chapterIndex: 3,
          chapterPosition: 27,
          chapterName: "Chapter Four",
          bookText: "selected",
          content: "context"
        )
      ]
    )
  }
}

private actor BackupRepositoryStub: AndroidLibraryBackupRepository {
  let plan: AndroidLibraryRestorePlan
  let records: [ReadRecord]
  let tocRules: [LocalTextTOCRule]
  let readerConfig: AndroidReaderConfigBundle?
  let storedDictionaryRules: [DictionaryRule]

  init(
    plan: AndroidLibraryRestorePlan,
    records: [ReadRecord] = [],
    tocRules: [LocalTextTOCRule] = [],
    readerConfig: AndroidReaderConfigBundle? = nil,
    dictionaryRules: [DictionaryRule] = []
  ) {
    self.plan = plan
    self.records = records
    self.tocRules = tocRules
    self.readerConfig = readerConfig
    storedDictionaryRules = dictionaryRules
  }

  func androidLibraryBackupPlan() async throws -> AndroidLibraryRestorePlan {
    plan
  }

  func androidReadRecords() async throws -> [ReadRecord] {
    records
  }

  func localTextTOCRules() async throws -> [LocalTextTOCRule] {
    tocRules
  }

  func androidReaderConfigBundle() async throws -> AndroidReaderConfigBundle? {
    readerConfig
  }

  func dictionaryRules() async throws -> [DictionaryRule] {
    storedDictionaryRules
  }
}
