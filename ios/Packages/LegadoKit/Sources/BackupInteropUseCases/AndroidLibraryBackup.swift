import AndroidBackupInterop
import AppUseCases
import Foundation
import LegadoCore
import LibraryDomain
import ReaderCore

public struct AndroidLibraryBackupSummary: Equatable, Sendable {
  public let bookCount: Int
  public let groupCount: Int
  public let bookmarkCount: Int
  public let bookSourceCount: Int
  public let replacementRuleCount: Int
  public let readRecordCount: Int
  public let searchHistoryCount: Int
  public let ruleSubscriptionCount: Int
  public let rssSourceCount: Int
  public let rssStarCount: Int
  public let httpTextToSpeechEngineCount: Int
  public let localTextTOCRuleCount: Int
  public let readerConfigCount: Int
  public let dictionaryRuleCount: Int
  public let keyboardAssistCount: Int
  public let themeConfigCount: Int
  public let webDAVConfigurationCount: Int
  public let webDAVServerProfileCount: Int

  public init(
    bookCount: Int,
    groupCount: Int,
    bookmarkCount: Int,
    bookSourceCount: Int = 0,
    replacementRuleCount: Int = 0,
    readRecordCount: Int = 0,
    searchHistoryCount: Int = 0,
    ruleSubscriptionCount: Int = 0,
    rssSourceCount: Int = 0,
    rssStarCount: Int = 0,
    httpTextToSpeechEngineCount: Int = 0,
    localTextTOCRuleCount: Int = 0,
    readerConfigCount: Int = 0,
    dictionaryRuleCount: Int = 0,
    keyboardAssistCount: Int = 0,
    themeConfigCount: Int = 0,
    webDAVConfigurationCount: Int = 0,
    webDAVServerProfileCount: Int = 0
  ) {
    self.bookCount = bookCount
    self.groupCount = groupCount
    self.bookmarkCount = bookmarkCount
    self.bookSourceCount = bookSourceCount
    self.replacementRuleCount = replacementRuleCount
    self.readRecordCount = readRecordCount
    self.searchHistoryCount = searchHistoryCount
    self.ruleSubscriptionCount = ruleSubscriptionCount
    self.rssSourceCount = rssSourceCount
    self.rssStarCount = rssStarCount
    self.httpTextToSpeechEngineCount = httpTextToSpeechEngineCount
    self.localTextTOCRuleCount = localTextTOCRuleCount
    self.readerConfigCount = readerConfigCount
    self.dictionaryRuleCount = dictionaryRuleCount
    self.keyboardAssistCount = keyboardAssistCount
    self.themeConfigCount = themeConfigCount
    self.webDAVConfigurationCount = webDAVConfigurationCount
    self.webDAVServerProfileCount = webDAVServerProfileCount
  }
}

public struct AndroidWebDAVBackupExportInput: Equatable, Sendable {
  public let serverAddress: String
  public let username: String
  public let password: String
  public let directoryName: String
  public let backupPassword: String
  public let syncBookProgress: Bool
  public let webDAVDeviceName: String
  public let onlyLatestBackup: Bool

  public init(
    serverAddress: String,
    username: String,
    password: String,
    directoryName: String,
    backupPassword: String,
    syncBookProgress: Bool = true,
    webDAVDeviceName: String = "iOS",
    onlyLatestBackup: Bool = true
  ) {
    self.serverAddress = serverAddress
    self.username = username
    self.password = password
    self.directoryName = directoryName
    self.backupPassword = backupPassword
    self.syncBookProgress = syncBookProgress
    self.webDAVDeviceName = webDAVDeviceName
    self.onlyLatestBackup = onlyLatestBackup
  }
}

public struct AndroidApplicationBackupExportInput: Equatable, Sendable {
  public let showsDiscovery: Bool
  public let showsRSS: Bool
  public let bookshelfSort: ShelfSortMode

  public init(
    showsDiscovery: Bool,
    showsRSS: Bool,
    bookshelfSort: ShelfSortMode
  ) {
    self.showsDiscovery = showsDiscovery
    self.showsRSS = showsRSS
    self.bookshelfSort = bookshelfSort
  }
}

public struct AndroidWebDAVServerProfileExportInput: Equatable, Sendable {
  public let id: Int64
  public let name: String
  public let serverAddress: String
  public let username: String
  public let password: String
  public let sortNumber: Int

  public init(
    id: Int64,
    name: String,
    serverAddress: String,
    username: String,
    password: String,
    sortNumber: Int
  ) {
    self.id = id
    self.name = name
    self.serverAddress = serverAddress
    self.username = username
    self.password = password
    self.sortNumber = sortNumber
  }
}

public protocol AndroidLibraryBackupRepository: Sendable {
  func androidLibraryBackupPlan() async throws -> AndroidLibraryRestorePlan
  func androidReadRecords() async throws -> [ReadRecord]
  func androidSearchHistory() async throws -> [SearchHistoryEntry]
  func androidRuleSubscriptions() async throws -> [RuleSubscription]
  func androidRSSSources() async throws -> [RSSSource]
  func androidRSSStars() async throws -> [RSSStar]
  func androidHTTPTextToSpeechEngines() async throws -> [HTTPTextToSpeechEngine]
  func localTextTOCRules() async throws -> [LocalTextTOCRule]
  func androidReaderConfigBundle() async throws -> AndroidReaderConfigBundle?
  func dictionaryRules() async throws -> [DictionaryRule]
  func keyboardAssists() async throws -> [KeyboardAssist]
  func appThemeProfiles() async throws -> [AppThemeProfile]
  func directLinkUploadRule() async throws -> DirectLinkUploadRule?
}

public extension AndroidLibraryBackupRepository {
  func androidReadRecords() async throws -> [ReadRecord] { [] }
  func androidSearchHistory() async throws -> [SearchHistoryEntry] { [] }
  func androidRuleSubscriptions() async throws -> [RuleSubscription] { [] }
  func androidRSSSources() async throws -> [RSSSource] { [] }
  func androidRSSStars() async throws -> [RSSStar] { [] }
  func androidHTTPTextToSpeechEngines() async throws -> [HTTPTextToSpeechEngine] { [] }
  func keyboardAssists() async throws -> [KeyboardAssist] { [] }
  func appThemeProfiles() async throws -> [AppThemeProfile] { [] }
  func directLinkUploadRule() async throws -> DirectLinkUploadRule? { nil }
}

public enum AndroidLibraryBackupError: Error, Equatable, Sendable {
  case integerOutOfRange(field: String, value: Int64)
  case backupPasswordRequired
}

public struct AndroidLibraryBackupUseCase: Sendable {
  private let repository: any AndroidLibraryBackupRepository

  public init(repository: any AndroidLibraryBackupRepository) {
    self.repository = repository
  }

  public func export(to archiveURL: URL) async throws
    -> AndroidLibraryBackupSummary
  {
    try await export(
      to: archiveURL,
      bookSources: [],
      replacementRules: []
    )
  }

  public func export(
    to archiveURL: URL,
    bookSources: [BookSourceDraft],
    replacementRules: [ReaderReplacementRule],
    readerPreferences: ReaderPreferences? = nil
  ) async throws -> AndroidLibraryBackupSummary {
    try await export(
      to: archiveURL,
      bookSources: bookSources,
      replacementRules: replacementRules,
      readerPreferences: readerPreferences,
      webDAVConfiguration: nil,
      webDAVServerProfiles: [],
      selectedWebDAVServerID: nil,
      backupPassword: nil
    )
  }

  public func export(
    to archiveURL: URL,
    bookSources: [BookSourceDraft],
    replacementRules: [ReaderReplacementRule],
    readerPreferences: ReaderPreferences?,
    applicationPreferences: AndroidApplicationBackupExportInput? = nil,
    webDAVConfiguration: AndroidWebDAVBackupExportInput?,
    webDAVServerProfiles: [AndroidWebDAVServerProfileExportInput] = [],
    selectedWebDAVServerID: Int64? = nil,
    backupPassword: String? = nil
  ) async throws -> AndroidLibraryBackupSummary {
    let plan = try await repository.androidLibraryBackupPlan()
    let readRecords = try await repository.androidReadRecords()
    let searchHistory = try await repository.androidSearchHistory()
    let ruleSubscriptions = try await repository.androidRuleSubscriptions()
    let rssSources = try await repository.androidRSSSources()
    let rssStars = try await repository.androidRSSStars()
    let httpTextToSpeechEngines = try await repository.androidHTTPTextToSpeechEngines()
    let localTextTOCRules = try await repository.localTextTOCRules()
    let storedReaderConfigBundle = try await repository.androidReaderConfigBundle()
    let readerConfigBundle = readerPreferences.map {
      (storedReaderConfigBundle ?? AndroidReaderConfigBundle(
        styles: [],
        sharedStyle: nil
      )).applying($0)
    } ?? storedReaderConfigBundle
    let dictionaryRules = try await repository.dictionaryRules()
    let keyboardAssists = try await repository.keyboardAssists()
    let themeProfiles = try await repository.appThemeProfiles()
    let directLinkUploadRule = try await repository.directLinkUploadRule()
    var contents = try AndroidLibraryBackupAdapter.contents(
      from: plan,
      bookSources: bookSources,
      replacementRules: replacementRules,
      readRecords: readRecords,
      searchHistory: searchHistory,
      ruleSubscriptions: ruleSubscriptions,
      rssSources: rssSources,
      rssStars: rssStars,
      httpTextToSpeechEngines: httpTextToSpeechEngines,
      localTextTOCRules: localTextTOCRules,
      readerConfigBundle: readerConfigBundle,
      dictionaryRules: dictionaryRules,
      keyboardAssists: keyboardAssists,
      themeProfiles: themeProfiles,
      directLinkUploadRule: directLinkUploadRule,
      sharedPreferences: try Self.sharedPreferences(
        webDAVConfiguration,
        applicationPreferences: applicationPreferences,
        selectedServerID: selectedWebDAVServerID
      )
    )
    if !webDAVServerProfiles.isEmpty {
      guard let backupPassword else {
        throw AndroidLibraryBackupError.backupPasswordRequired
      }
      contents.serverProfilesPayload = try AndroidServerProfileCodec
        .encodeArchivePayload(
          try webDAVServerProfiles.map(Self.serverProfileDTO),
          backupPassword: backupPassword
        )
    }
    try AndroidBackupArchive.write(
      contents,
      to: archiveURL
    )
    return AndroidLibraryBackupSummary(
      bookCount: plan.books.count,
      groupCount: plan.groups.count,
      bookmarkCount: plan.bookmarks.count,
      bookSourceCount: contents.bookSources.count,
      replacementRuleCount: contents.replacementRules.count,
      readRecordCount: contents.readRecords.count,
      searchHistoryCount: contents.searchHistory.count,
      ruleSubscriptionCount: contents.ruleSubscriptions.count,
      rssSourceCount: contents.rssSources.count,
      rssStarCount: contents.rssStars.count,
      httpTextToSpeechEngineCount: contents.httpTextToSpeechEngines.count,
      localTextTOCRuleCount: contents.localTextTOCRules.count,
      readerConfigCount: contents.readerConfigs.count
        + (contents.sharedReaderConfig == nil ? 0 : 1),
      dictionaryRuleCount: contents.dictionaryRules.count,
      keyboardAssistCount: contents.keyboardAssists.count,
      themeConfigCount: contents.themeConfigs.count,
      webDAVConfigurationCount: webDAVConfiguration == nil ? 0 : 1,
      webDAVServerProfileCount: webDAVServerProfiles.count
    )
  }

  private static func sharedPreferences(
    _ input: AndroidWebDAVBackupExportInput?,
    applicationPreferences: AndroidApplicationBackupExportInput?,
    selectedServerID: Int64?
  ) throws -> AndroidSharedPreferencesDocument? {
    var values: [String: AndroidSharedPreferenceValue] = [:]
    if let input {
      values[AndroidWebDAVBackupConfiguration.serverAddressKey] =
        .string(input.serverAddress)
      values[AndroidWebDAVBackupConfiguration.usernameKey] =
        .string(input.username)
      values[AndroidWebDAVBackupConfiguration.passwordKey] =
        .string(
          try AndroidBackupAES.encryptBase64(
            input.password,
            backupPassword: input.backupPassword
          )
        )
      values[AndroidWebDAVBackupConfiguration.directoryNameKey] =
        .string(input.directoryName)
      values[AndroidWebDAVBackupConfiguration.syncBookProgressKey] =
        .boolean(input.syncBookProgress)
      values[AndroidWebDAVBackupConfiguration.webDAVDeviceNameKey] =
        .string(input.webDAVDeviceName)
      values[AndroidWebDAVBackupConfiguration.onlyLatestBackupKey] =
        .boolean(input.onlyLatestBackup)
    }
    if let selectedServerID {
      values[AndroidWebDAVBackupConfiguration.remoteServerIDKey] =
        .long(selectedServerID)
    }
    if let applicationPreferences {
      values[AndroidApplicationBackupPreferences.showDiscoveryKey] =
        .boolean(applicationPreferences.showsDiscovery)
      values[AndroidApplicationBackupPreferences.showRSSKey] =
        .boolean(applicationPreferences.showsRSS)
      values[AndroidApplicationBackupPreferences.bookshelfSortKey] =
        .int(Int32(applicationPreferences.bookshelfSort.rawValue))
    }
    return values.isEmpty ? nil : AndroidSharedPreferencesDocument(values: values)
  }

  private static func serverProfileDTO(
    _ input: AndroidWebDAVServerProfileExportInput
  ) throws -> AndroidServerProfileDTO {
    let config = try JSONValueCodec.encode(
      .object([
        "url": .string(input.serverAddress),
        "username": .string(input.username),
        "password": .string(input.password),
      ])
    )
    guard let configString = String(data: config, encoding: .utf8) else {
      throw AndroidServerProfileCodecError.invalidPayloadEncoding
    }
    return AndroidServerProfileDTO(
      id: input.id,
      name: input.name,
      config: configString,
      sortNumber: input.sortNumber
    )
  }
}

public enum AndroidLibraryBackupAdapter {
  public static func contents(from plan: AndroidLibraryRestorePlan) throws
    -> AndroidBackupContents
  {
    try contents(
      from: plan,
      bookSources: [],
      replacementRules: [],
      readRecords: [],
      searchHistory: [],
      ruleSubscriptions: [],
      rssSources: [],
      rssStars: [],
      httpTextToSpeechEngines: [],
      localTextTOCRules: [],
      readerConfigBundle: nil,
      dictionaryRules: [],
      keyboardAssists: [],
      themeProfiles: [],
      sharedPreferences: nil
    )
  }

  public static func contents(
    from plan: AndroidLibraryRestorePlan,
    bookSources: [BookSourceDraft],
    replacementRules: [ReaderReplacementRule],
    readRecords: [ReadRecord] = [],
    searchHistory: [SearchHistoryEntry] = [],
    ruleSubscriptions: [RuleSubscription] = [],
    rssSources: [RSSSource] = [],
    rssStars: [RSSStar] = [],
    httpTextToSpeechEngines: [HTTPTextToSpeechEngine] = [],
    localTextTOCRules: [LocalTextTOCRule] = [],
    readerConfigBundle: AndroidReaderConfigBundle? = nil,
    dictionaryRules: [DictionaryRule] = [],
    keyboardAssists: [KeyboardAssist] = [],
    themeProfiles: [AppThemeProfile] = [],
    directLinkUploadRule: DirectLinkUploadRule? = nil,
    sharedPreferences: AndroidSharedPreferencesDocument? = nil
  ) throws -> AndroidBackupContents {
    let sourceData = try SourceManagementPolicy.exportData(
      bookSources,
      selectedIDs: Set(bookSources.map(\.sourceURL))
    )
    return AndroidBackupContents(
      bookSources: try AndroidBackupArchive.decodeBookSources(sourceData),
      replacementRules: try replacementRules.map(mapReplacementRule),
      books: try plan.books.map(mapBook),
      bookGroups: try plan.groups.map(mapGroup),
      bookmarks: try plan.bookmarks.map(mapBookmark),
      readRecords: AndroidReadRecordInteropAdapter.backupDocuments(readRecords),
      searchHistory: AndroidSearchHistoryInteropAdapter.backupDocuments(searchHistory),
      ruleSubscriptions: AndroidRuleSubscriptionInteropAdapter.backupDocuments(
        ruleSubscriptions
      ),
      rssSources: AndroidRSSInteropAdapter.backupSources(rssSources),
      rssStars: AndroidRSSInteropAdapter.backupStars(rssStars),
      httpTextToSpeechEngines:
        AndroidHTTPTextToSpeechInteropAdapter.backupDocuments(
          httpTextToSpeechEngines
        ),
      localTextTOCRules:
        AndroidLocalTextTOCRuleInteropAdapter.backupDocuments(localTextTOCRules),
      readerConfigs: readerConfigBundle?.styles ?? [],
      sharedReaderConfig: readerConfigBundle?.sharedStyle,
      dictionaryRules:
        AndroidDictionaryRuleInteropAdapter.backupDocuments(dictionaryRules),
      keyboardAssists:
        AndroidKeyboardAssistInteropAdapter.backupDocuments(keyboardAssists),
      themeConfigs:
        AndroidThemeConfigInteropAdapter.backupDocuments(themeProfiles),
      directLinkUploadRule:
        AndroidDirectLinkUploadRuleInteropAdapter.backupDocument(
          directLinkUploadRule
        ),
      sharedPreferences: sharedPreferences
    )
  }

  private static func mapReplacementRule(
    _ value: ReaderReplacementRule
  ) throws -> AndroidReplaceRuleDTO {
    AndroidReplaceRuleDTO(
      id: Int64(value.id) ?? stableAndroidID(value.id),
      name: value.name,
      pattern: value.pattern,
      replacement: value.replacement,
      scope: value.scope,
      scopeTitle: value.appliesToTitle,
      scopeContent: value.appliesToContent,
      excludeScope: value.excludeScope,
      isEnabled: value.isEnabled,
      isRegex: value.isRegex,
      order: try int32(Int64(value.order), field: "replaceRule.order")
    )
  }

  private static func stableAndroidID(_ value: String) -> Int64 {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in value.utf8 {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    let positive = hash & UInt64(Int64.max)
    return positive == 0 ? 1 : Int64(positive)
  }

  private static func mapBook(_ value: AndroidLibraryRestoreBook) throws
    -> AndroidBookDTO
  {
    AndroidBookDTO(
      bookURL: value.candidate.bookURL,
      tocURL: value.candidate.tocURL ?? "",
      origin: value.candidate.sourceID,
      originName: value.candidate.originName,
      name: value.candidate.name,
      author: value.candidate.author,
      kind: value.candidate.kind,
      customTag: value.customTag,
      coverURL: value.candidate.coverURL,
      customCoverURL: value.candidate.customCoverURL,
      intro: value.candidate.intro,
      customIntro: value.candidate.customIntro,
      charset: value.charset,
      type: try int32(value.androidType, field: "type"),
      group: value.groupMask,
      latestChapterTitle: value.candidate.lastChapter,
      latestChapterTime: value.latestChapterTime,
      lastCheckTime: value.lastCheckTime,
      lastCheckCount: try int32(
        Int64(value.latestCheckCount), field: "lastCheckCount"
      ),
      totalChapterCount: try int32(
        Int64(value.chapterCount), field: "totalChapterNum"
      ),
      currentChapterTitle: value.progress.chapterTitle,
      currentChapterIndex: try int32(
        Int64(value.progress.position.chapterIndex), field: "durChapterIndex"
      ),
      currentChapterPosition: try int32(
        Int64(value.progress.position.characterOffset), field: "durChapterPos"
      ),
      lastReadTime: value.progress.updatedAtMilliseconds,
      wordCount: value.wordCount,
      canUpdate: value.canUpdate,
      order: try int32(value.order, field: "order"),
      originOrder: try int32(value.originOrder, field: "originOrder"),
      variable: try encodedVariables(value.candidate.variables),
      readConfig: [
        "reverseToc": .bool(value.reversesTableOfContents),
        "splitLongChapter": .bool(value.splitsLongChapters),
      ],
      syncTime: value.syncTime
    )
  }

  private static func mapGroup(_ value: AndroidLibraryRestoreGroup) throws
    -> AndroidBookGroupDTO
  {
    AndroidBookGroupDTO(
      groupID: value.id,
      groupName: value.name,
      cover: value.cover,
      order: try int32(Int64(value.order), field: "bookGroup.order"),
      enableRefresh: value.enablesRefresh,
      show: value.isShown,
      bookSort: try int32(Int64(value.bookSort), field: "bookGroup.bookSort")
    )
  }

  private static func mapBookmark(_ value: Bookmark) throws
    -> AndroidBookmarkDTO
  {
    AndroidBookmarkDTO(
      time: value.time,
      bookName: value.bookName,
      bookAuthor: value.bookAuthor,
      chapterIndex: try int32(
        Int64(value.chapterIndex), field: "bookmark.chapterIndex"
      ),
      chapterPosition: try int32(
        Int64(value.chapterPosition), field: "bookmark.chapterPos"
      ),
      chapterName: value.chapterName,
      bookText: value.bookText,
      content: value.content
    )
  }

  private static func int32(_ value: Int64, field: String) throws -> Int32 {
    guard let result = Int32(exactly: value) else {
      throw AndroidLibraryBackupError.integerOutOfRange(
        field: field,
        value: value
      )
    }
    return result
  }

  private static func encodedVariables(_ variables: [String: String]) throws
    -> String?
  {
    guard !variables.isEmpty else { return nil }
    let data = try JSONSerialization.data(
      withJSONObject: variables,
      options: [.sortedKeys]
    )
    return String(decoding: data, as: UTF8.self)
  }
}
