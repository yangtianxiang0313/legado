import AndroidBackupInterop
import AppUseCases
import BackupInteropUseCases
import Foundation
import LibraryDomain
import ReaderCore
import Testing

@Suite("AndroidCoreBackupRestoreUseCaseTests")
struct AndroidCoreBackupRestoreUseCaseTests {
  @Test func restoresEveryPresentCoreDomain() async throws {
    let repository = CoreRestoreRepositoryStub()
    let useCase = AndroidCoreBackupRestoreUseCase(repository: repository)
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let archiveURL = directory.appendingPathComponent("backup.zip")
    let source = try #require(
      AndroidBackupArchive.decodeBookSources(
        Data(
          #"[{"bookSourceUrl":"https://android.invalid/source","bookSourceName":"Android Source","searchUrl":"https://android.invalid/search?key={{key}}","ruleSearch":{"bookList":"$.books[*]"},"enabled":false}]"#.utf8
        )
      ).first
    )
    let tocRule = try #require(
      AndroidLocalTextTOCRuleCodec.decodeMany(
        Data(#"[{"id":7,"name":"卷章","rule":"^卷.+$","serialNumber":1,"enable":true}]"#.utf8)
      ).first
    )
    let readerStyle = try #require(
      AndroidReaderConfigCodec.decodeList(
        Data(#"[{"name":"paper","textSize":18}]"#.utf8)
      ).first
    )
    let sharedReaderStyle = try AndroidReaderConfigCodec.decodeShared(
      Data(#"{"name":"shared","textSize":26,"lineSpacingExtra":12}"#.utf8)
    )
    let dictionaryRule = try #require(
      AndroidDictionaryRuleCodec.decodeMany(
        Data(#"[{"name":"词典","urlRule":"https://dict.invalid/{{key}}","enabled":true,"sortNumber":2}]"#.utf8)
      ).first
    )
    try AndroidBackupArchive.write(
      AndroidBackupContents(
        bookSources: [source],
        replacementRules: [
          AndroidReplaceRuleDTO(
            id: 42,
            name: "去广告",
            pattern: "ad",
            replacement: "",
            order: 3
          )
        ],
        readRecords: [
          AndroidReadRecordDTO(
            deviceID: "android-device",
            bookName: "Android Book",
            readTime: 3_600,
            lastRead: 1_700_000_000_789
          )
        ],
        localTextTOCRules: [tocRule],
        readerConfigs: [readerStyle],
        sharedReaderConfig: sharedReaderStyle,
        dictionaryRules: [dictionaryRule],
        sharedPreferences: AndroidSharedPreferencesDocument(values: [
          AndroidApplicationBackupPreferences.showDiscoveryKey: .boolean(false),
          AndroidApplicationBackupPreferences.showRSSKey: .boolean(false),
          AndroidApplicationBackupPreferences.bookshelfSortKey: .int(4),
          AndroidApplicationBackupPreferences.defaultHomePageKey: .string("my"),
          AndroidApplicationBackupPreferences.enableReadRecordKey: .boolean(false),
          AndroidApplicationBackupPreferences.searchScopeKey: .string("科幻"),
          AndroidApplicationBackupPreferences.searchGroupKey: .string("科幻"),
          AndroidApplicationBackupPreferences.autoChangeSourceKey: .boolean(false),
          AndroidApplicationBackupPreferences.changeSourceCheckAuthorKey:
            .boolean(true),
          AndroidApplicationBackupPreferences.ttsFollowSystemKey: .boolean(false),
          AndroidApplicationBackupPreferences.ttsSpeechRateKey: .int(15),
        ])
      ),
      to: archiveURL
    )

    let summary = try await useCase.restore(from: archiveURL)
    let snapshot = await repository.snapshot()

    #expect(summary.bookCount == 0)
    #expect(summary.groupCount == 0)
    #expect(summary.bookmarkCount == 0)
    #expect(summary.bookSourceCount == 1)
    #expect(summary.replacementRuleCount == 1)
    #expect(summary.readRecordCount == 1)
    #expect(summary.localTextTOCRuleCount == 1)
    #expect(summary.readerConfigCount == 2)
    #expect(summary.dictionaryRuleCount == 1)
    #expect(summary.applicationPreferenceCount == 11)
    #expect(Set(summary.preflight.members.map(\.path)) == Set([
      "bookSource.json", "config.xml", "dictRule.json", "readConfig.json",
      "readRecord.json", "replaceRule.json", "shareReadConfig.json",
      "txtTocRule.json",
    ]))
    #expect(summary.preflight.members.allSatisfy {
      $0.disposition == .supported
    })
    #expect(snapshot.sources.first?.sourceURL == "https://android.invalid/source")
    #expect(snapshot.rules.first?.id == "42")
    #expect(snapshot.rules.first?.name == "去广告")
    #expect(snapshot.rules.first?.order == 3)
    #expect(snapshot.records.first?.deviceID == "android-device")
    #expect(snapshot.records.first?.readTime == 3_600)
    #expect(snapshot.tocRules.first?.name == "卷章")
    #expect(snapshot.readerConfig?.projection?.fontSize == 26)
    #expect(snapshot.dictionaryRules.first?.name == "词典")
    #expect(snapshot.navigationPreferences?.showsExplore == false)
    #expect(snapshot.navigationPreferences?.showsRSS == false)
    #expect(snapshot.navigationPreferences?.defaultHomePage == .settings)
    #expect(snapshot.globalShelfSortMode == .combinedTime)
    #expect(snapshot.readAloudPreferences?.followsSystemRate == false)
    #expect(snapshot.readAloudPreferences?.speechRatePreference == 15)
    #expect(snapshot.readingHistoryPreferences?.recordsReadingTime == false)
    #expect(snapshot.searchScopePreferences?.serializedScope == "科幻")
    #expect(snapshot.searchScopePreferences?.changeSourceGroup == "科幻")
    #expect(
      snapshot.sourceSwitchPreferences?.automaticallyRecoversMissingSource
        == false
    )
    #expect(snapshot.sourceSwitchPreferences?.requiresAuthorMatch == true)
  }

}

private actor CoreRestoreRepositoryStub: AndroidCoreBackupRestoreRepository {
  private var sources: [BookSourceDraft] = []
  private var rules: [ReaderReplacementRule] = []
  private var records: [ReadRecord] = []
  private var tocRules: [LocalTextTOCRule] = []
  private var readerConfig: AndroidReaderConfigBundle?
  private var dictionaryRules: [DictionaryRule] = []
  private var navigationPreferences: AndroidNavigationPreferencesImportPlan?
  private var globalShelfSortMode: ShelfSortMode?
  private var readAloudPreferences: AndroidReadAloudPreferencesImportPlan?
  private var readingHistoryPreferences:
    AndroidReadingHistoryPreferencesImportPlan?
  private var searchScopePreferences: AndroidSearchScopePreferencesImportPlan?
  private var sourceSwitchPreferences: AndroidSourceSwitchPreferencesImportPlan?

  func restoreAndroidDatabaseDomains(
    _ payload: AndroidCoreDatabaseRestorePayload
  ) async throws -> AndroidLibraryRestoreSummary {
    rules = payload.replacementRules
    records = payload.readRecords
    tocRules = payload.localTextTOCRules
    readerConfig = payload.readerConfigBundle
    dictionaryRules = payload.dictionaryRules
    globalShelfSortMode = payload.globalShelfSortMode
    return AndroidLibraryRestoreSummary(
      bookCount: payload.library.books.count,
      groupCount: payload.library.groups.count,
      bookmarkCount: payload.library.bookmarks.count
    )
  }

  func restoreAndroidLibrary(
    _ plan: AndroidLibraryRestorePlan
  ) async throws -> AndroidLibraryRestoreSummary {
    AndroidLibraryRestoreSummary(
      bookCount: plan.books.count,
      groupCount: plan.groups.count,
      bookmarkCount: plan.bookmarks.count
    )
  }

  func restoreAndroidBookSources(_ sources: [BookSourceDraft]) async throws {
    self.sources = sources
  }

  func restoreAndroidReplacementRules(
    _ rules: [ReaderReplacementRule]
  ) async throws {
    self.rules = rules
  }

  func restoreAndroidReadRecords(_ records: [ReadRecord]) async throws {
    self.records = records
  }

  func restoreAndroidLocalTextTOCRules(
    _ values: [LocalTextTOCRule]
  ) async throws {
    tocRules = values
  }

  func restoreAndroidReaderConfigBundle(
    _ bundle: AndroidReaderConfigBundle
  ) async throws {
    readerConfig = bundle
  }

  func restoreAndroidDictionaryRules(
    _ values: [DictionaryRule]
  ) async throws {
    dictionaryRules = values
  }

  func restoreAndroidNavigationPreferences(
    _ plan: AndroidNavigationPreferencesImportPlan
  ) async throws {
    navigationPreferences = plan
  }

  func restoreAndroidReadAloudPreferences(
    _ plan: AndroidReadAloudPreferencesImportPlan
  ) async throws {
    readAloudPreferences = plan
  }

  func restoreAndroidReadingHistoryPreferences(
    _ plan: AndroidReadingHistoryPreferencesImportPlan
  ) async throws {
    readingHistoryPreferences = plan
  }

  func restoreAndroidSearchScopePreferences(
    _ plan: AndroidSearchScopePreferencesImportPlan
  ) async throws {
    searchScopePreferences = plan
  }

  func restoreAndroidSourceSwitchPreferences(
    _ plan: AndroidSourceSwitchPreferencesImportPlan
  ) async throws {
    sourceSwitchPreferences = plan
  }

  func snapshot() -> (
    sources: [BookSourceDraft],
    rules: [ReaderReplacementRule],
    records: [ReadRecord],
    tocRules: [LocalTextTOCRule],
    readerConfig: AndroidReaderConfigBundle?,
    dictionaryRules: [DictionaryRule],
    navigationPreferences: AndroidNavigationPreferencesImportPlan?,
    globalShelfSortMode: ShelfSortMode?,
    readAloudPreferences: AndroidReadAloudPreferencesImportPlan?,
    readingHistoryPreferences: AndroidReadingHistoryPreferencesImportPlan?,
    searchScopePreferences: AndroidSearchScopePreferencesImportPlan?,
    sourceSwitchPreferences: AndroidSourceSwitchPreferencesImportPlan?
  ) {
    (
      sources, rules, records, tocRules, readerConfig, dictionaryRules,
      navigationPreferences, globalShelfSortMode, readAloudPreferences,
      readingHistoryPreferences, searchScopePreferences,
      sourceSwitchPreferences
    )
  }
}
