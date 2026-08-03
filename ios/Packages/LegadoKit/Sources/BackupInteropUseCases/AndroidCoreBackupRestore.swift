import AndroidBackupInterop
import AppUseCases
import Foundation
import LibraryDomain
import ReaderCore

public struct AndroidCoreBackupRestoreSummary: Equatable, Sendable {
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
  public let readerConfigProjection: AndroidReaderConfigProjection?
  public let dictionaryRuleCount: Int
  public let keyboardAssistCount: Int
  public let themeConfigCount: Int
  public let webDAVConfigurationCount: Int
  public let webDAVServerProfileCount: Int
  public let preflight: AndroidBackupPreflightReport

  public init(
    bookCount: Int,
    groupCount: Int,
    bookmarkCount: Int,
    bookSourceCount: Int,
    replacementRuleCount: Int,
    readRecordCount: Int = 0,
    searchHistoryCount: Int = 0,
    ruleSubscriptionCount: Int = 0,
    rssSourceCount: Int = 0,
    rssStarCount: Int = 0,
    httpTextToSpeechEngineCount: Int = 0,
    localTextTOCRuleCount: Int = 0,
    readerConfigCount: Int = 0,
    readerConfigProjection: AndroidReaderConfigProjection? = nil,
    dictionaryRuleCount: Int = 0,
    keyboardAssistCount: Int = 0,
    themeConfigCount: Int = 0,
    webDAVConfigurationCount: Int = 0,
    webDAVServerProfileCount: Int = 0,
    preflight: AndroidBackupPreflightReport = .init(members: [])
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
    self.readerConfigProjection = readerConfigProjection
    self.dictionaryRuleCount = dictionaryRuleCount
    self.keyboardAssistCount = keyboardAssistCount
    self.themeConfigCount = themeConfigCount
    self.webDAVConfigurationCount = webDAVConfigurationCount
    self.webDAVServerProfileCount = webDAVServerProfileCount
    self.preflight = preflight
  }
}

public enum AndroidWebDAVCredentialImportState: Equatable, Sendable {
  case missing
  case unresolvedAndroidBackupPayload(username: String?, payload: String)
  case resolved(username: String, password: String)
}

public enum AndroidCoreBackupRestoreError: Error, Equatable, Sendable {
  case backupPasswordRequired
  case invalidBackupPassword
  case preflightRejected(AndroidBackupPreflightReport)
}

public struct AndroidWebDAVConfigurationImportPlan: Equatable, Sendable {
  public let settings: WebDAVConnectionSettings
  public let credential: AndroidWebDAVCredentialImportState

  public init(
    settings: WebDAVConnectionSettings,
    credential: AndroidWebDAVCredentialImportState
  ) {
    self.settings = settings
    self.credential = credential
  }
}

public protocol AndroidCoreBackupRestoreRepository: Sendable {
  func restoreAndroidLibrary(
    _ plan: AndroidLibraryRestorePlan
  ) async throws -> AndroidLibraryRestoreSummary
  func restoreAndroidBookSources(_ sources: [BookSourceDraft]) async throws
  func restoreAndroidReplacementRules(
    _ rules: [ReaderReplacementRule]
  ) async throws
  func restoreAndroidReadRecords(_ records: [LibraryDomain.ReadRecord]) async throws
  func restoreAndroidSearchHistory(_ entries: [SearchHistoryEntry]) async throws
  func restoreAndroidRuleSubscriptions(_ values: [RuleSubscription]) async throws
  func restoreAndroidRSS(sources: [RSSSource], stars: [RSSStar]) async throws
  func restoreAndroidHTTPTextToSpeechEngines(
    _ values: [HTTPTextToSpeechEngine]
  ) async throws
  func restoreAndroidLocalTextTOCRules(
    _ values: [LocalTextTOCRule]
  ) async throws
  func restoreAndroidReaderConfigBundle(
    _ bundle: AndroidReaderConfigBundle
  ) async throws
  func restoreAndroidDictionaryRules(_ values: [DictionaryRule]) async throws
  func restoreAndroidKeyboardAssists(_ values: [KeyboardAssist]) async throws
  func restoreAndroidThemeProfiles(_ values: [AppThemeProfile]) async throws
  func restoreAndroidWebDAVConfiguration(
    _ plan: AndroidWebDAVConfigurationImportPlan
  ) async throws
  func restoreAndroidWebDAVServerProfiles(
    _ plan: AndroidServerProfileImportPlan
  ) async throws
}

public extension AndroidCoreBackupRestoreRepository {
  func restoreAndroidSearchHistory(
    _ entries: [SearchHistoryEntry]
  ) async throws {}

  func restoreAndroidRuleSubscriptions(
    _ values: [RuleSubscription]
  ) async throws {}

  func restoreAndroidRSS(
    sources: [RSSSource],
    stars: [RSSStar]
  ) async throws {}

  func restoreAndroidHTTPTextToSpeechEngines(
    _ values: [HTTPTextToSpeechEngine]
  ) async throws {}

  func restoreAndroidLocalTextTOCRules(
    _ values: [LocalTextTOCRule]
  ) async throws {}

  func restoreAndroidReaderConfigBundle(
    _ bundle: AndroidReaderConfigBundle
  ) async throws {}
  func restoreAndroidDictionaryRules(_ values: [DictionaryRule]) async throws {}
  func restoreAndroidKeyboardAssists(_ values: [KeyboardAssist]) async throws {}
  func restoreAndroidThemeProfiles(_ values: [AppThemeProfile]) async throws {}
  func restoreAndroidWebDAVConfiguration(
    _ plan: AndroidWebDAVConfigurationImportPlan
  ) async throws {}
  func restoreAndroidWebDAVServerProfiles(
    _ plan: AndroidServerProfileImportPlan
  ) async throws {}
}

public struct AndroidCoreBackupRestoreUseCase: Sendable {
  private let repository: any AndroidCoreBackupRestoreRepository

  public init(repository: any AndroidCoreBackupRestoreRepository) {
    self.repository = repository
  }

  public func restore(
    from archiveURL: URL
  ) async throws -> AndroidCoreBackupRestoreSummary {
    try await restore(from: archiveURL, backupPassword: nil)
  }

  public func restore(
    from archiveURL: URL,
    backupPassword: String?
  ) async throws
    -> AndroidCoreBackupRestoreSummary
  {
    let preflight = AndroidBackupArchive.preflight(from: archiveURL)
    guard !preflight.hasBlockingIssues else {
      throw AndroidCoreBackupRestoreError.preflightRejected(preflight)
    }
    let libraryPlan = try AndroidLibraryImportAdapter.plan(from: archiveURL)
    let bookSourceDTOs = try AndroidBackupArchive.readBookSources(
      from: archiveURL
    )
    let bookSources = try SourceDefinitionImport.decode(
      AndroidBackupArchive.encodeBookSources(bookSourceDTOs)
    )
    let replacementRules = try AndroidBackupArchive.readReplacementRules(
      from: archiveURL
    ).map(Self.mapReplacementRule)
    let readRecords = AndroidReadRecordInteropAdapter.restoreValues(
      try AndroidBackupArchive.readReadRecords(from: archiveURL)
    )
    let searchHistory = AndroidSearchHistoryInteropAdapter.restoreValues(
      try AndroidBackupArchive.readSearchHistory(from: archiveURL)
    )
    let ruleSubscriptions = AndroidRuleSubscriptionInteropAdapter.restoreValues(
      try AndroidBackupArchive.readRuleSubscriptions(from: archiveURL)
    )
    let rssSources = AndroidRSSInteropAdapter.restoreSources(
      try AndroidBackupArchive.readRSSSources(from: archiveURL)
    )
    let rssStars = AndroidRSSInteropAdapter.restoreStars(
      try AndroidBackupArchive.readRSSStars(from: archiveURL)
    )
    let httpTextToSpeechEngines =
      AndroidHTTPTextToSpeechInteropAdapter.restoreValues(
        try AndroidBackupArchive.readHTTPTextToSpeechEngines(from: archiveURL)
      )
    let localTextTOCRules = AndroidLocalTextTOCRuleInteropAdapter.restoreValues(
      try AndroidBackupArchive.readLocalTextTOCRules(from: archiveURL)
    )
    let readerConfigBundle = AndroidReaderConfigBundle(
      styles: try AndroidBackupArchive.readReaderConfigs(from: archiveURL),
      sharedStyle: try AndroidBackupArchive.readSharedReaderConfig(
        from: archiveURL
      )
    )
    let dictionaryRules = AndroidDictionaryRuleInteropAdapter.restoreValues(
      try AndroidBackupArchive.readDictionaryRules(from: archiveURL)
    )
    let keyboardAssists = AndroidKeyboardAssistInteropAdapter.restoreValues(
      try AndroidBackupArchive.readKeyboardAssists(from: archiveURL)
    )
    let themeProfiles = AndroidThemeConfigInteropAdapter.restoreValues(
      try AndroidBackupArchive.readThemeConfigs(from: archiveURL)
    )
    let sharedPreferences = try AndroidBackupArchive.readSharedPreferences(
      from: archiveURL
    )
    let projectedWebDAVConfiguration = sharedPreferences.map(
      AndroidWebDAVBackupConfiguration.init(document:)
    )
    let webDAVConfiguration = projectedWebDAVConfiguration.flatMap {
      $0.isPresent ? $0 : nil
    }
    let webDAVImportPlan = try webDAVConfiguration.map {
      try Self.webDAVImportPlan($0, backupPassword: backupPassword)
    }
    let serverProfilePlan: AndroidServerProfileImportPlan
    do {
      serverProfilePlan = try AndroidServerProfileImportAdapter.plan(
        from: archiveURL,
        backupPassword: backupPassword,
        selectedID: projectedWebDAVConfiguration?.remoteServerID
      )
    } catch AndroidServerProfileCodecError.backupPasswordRequired {
      throw AndroidCoreBackupRestoreError.backupPasswordRequired
    } catch AndroidServerProfileCodecError.invalidBackupPassword {
      throw AndroidCoreBackupRestoreError.invalidBackupPassword
    }

    if !serverProfilePlan.entries.isEmpty
      || serverProfilePlan.selectedID != nil
    {
      try await repository.restoreAndroidWebDAVServerProfiles(
        serverProfilePlan
      )
    }
    if let webDAVImportPlan {
      try await repository.restoreAndroidWebDAVConfiguration(
        webDAVImportPlan
      )
    }
    let library = try await repository.restoreAndroidLibrary(libraryPlan)
    if !bookSources.isEmpty {
      try await repository.restoreAndroidBookSources(bookSources)
    }
    if !replacementRules.isEmpty {
      try await repository.restoreAndroidReplacementRules(replacementRules)
    }
    if !readRecords.isEmpty {
      try await repository.restoreAndroidReadRecords(readRecords)
    }
    if !searchHistory.isEmpty {
      try await repository.restoreAndroidSearchHistory(searchHistory)
    }
    if !ruleSubscriptions.isEmpty {
      try await repository.restoreAndroidRuleSubscriptions(ruleSubscriptions)
    }
    if !rssSources.isEmpty || !rssStars.isEmpty {
      try await repository.restoreAndroidRSS(
        sources: rssSources,
        stars: rssStars
      )
    }
    if !httpTextToSpeechEngines.isEmpty {
      try await repository.restoreAndroidHTTPTextToSpeechEngines(
        httpTextToSpeechEngines
      )
    }
    if !localTextTOCRules.isEmpty {
      try await repository.restoreAndroidLocalTextTOCRules(localTextTOCRules)
    }
    if !readerConfigBundle.styles.isEmpty
      || readerConfigBundle.sharedStyle != nil
    {
      try await repository.restoreAndroidReaderConfigBundle(readerConfigBundle)
    }
    if !dictionaryRules.isEmpty {
      try await repository.restoreAndroidDictionaryRules(dictionaryRules)
    }
    if !keyboardAssists.isEmpty {
      try await repository.restoreAndroidKeyboardAssists(keyboardAssists)
    }
    if !themeProfiles.isEmpty {
      try await repository.restoreAndroidThemeProfiles(themeProfiles)
    }
    return AndroidCoreBackupRestoreSummary(
      bookCount: library.bookCount,
      groupCount: library.groupCount,
      bookmarkCount: library.bookmarkCount,
      bookSourceCount: bookSources.count,
      replacementRuleCount: replacementRules.count,
      readRecordCount: readRecords.count,
      searchHistoryCount: searchHistory.count,
      ruleSubscriptionCount: ruleSubscriptions.count,
      rssSourceCount: rssSources.count,
      rssStarCount: rssStars.count,
      httpTextToSpeechEngineCount: httpTextToSpeechEngines.count,
      localTextTOCRuleCount: localTextTOCRules.count,
      readerConfigCount: readerConfigBundle.styles.count
        + (readerConfigBundle.sharedStyle == nil ? 0 : 1),
      readerConfigProjection: readerConfigBundle.projection,
      dictionaryRuleCount: dictionaryRules.count,
      keyboardAssistCount: keyboardAssists.count,
      themeConfigCount: themeProfiles.count,
      webDAVConfigurationCount: webDAVConfiguration == nil ? 0 : 1,
      webDAVServerProfileCount: serverProfilePlan.webDAVProfiles.count,
      preflight: preflight
    )
  }

  private static func webDAVImportPlan(
    _ value: AndroidWebDAVBackupConfiguration,
    backupPassword: String?
  ) throws -> AndroidWebDAVConfigurationImportPlan {
    let credential: AndroidWebDAVCredentialImportState
    if let payload = value.unresolvedPasswordPayload, !payload.isEmpty {
      guard let backupPassword, !backupPassword.isEmpty else {
        throw AndroidCoreBackupRestoreError.backupPasswordRequired
      }
      let password: String
      do {
        password = try AndroidBackupAES.decryptBase64(
          payload,
          backupPassword: backupPassword
        )
      } catch {
        throw AndroidCoreBackupRestoreError.invalidBackupPassword
      }
      credential = .resolved(
        username: value.username ?? "",
        password: password
      )
    } else {
      credential = .missing
    }
    return AndroidWebDAVConfigurationImportPlan(
      settings: WebDAVConnectionSettings(
        serverAddress: value.serverAddress ?? "",
        directoryName: value.directoryName ?? "legado",
        syncBookProgress: value.syncBookProgress ?? true,
        webDAVDeviceName: value.webDAVDeviceName ?? "iOS",
        onlyLatestBackup: value.onlyLatestBackup ?? true
      ),
      credential: credential
    )
  }

  private static func mapReplacementRule(
    _ value: AndroidReplaceRuleDTO
  ) throws -> ReaderReplacementRule {
    let projection = value.restoreProjection
    guard let order = Int(exactly: projection.order) else {
      throw AndroidLibraryImportError.integerOutOfRange(
        field: "replaceRule.order",
        value: projection.order
      )
    }
    return ReaderReplacementRule(
      id: String(projection.id),
      name: projection.name,
      pattern: projection.pattern,
      replacement: projection.replacement,
      scope: projection.scope,
      excludeScope: projection.excludeScope,
      appliesToTitle: projection.scopeTitle,
      appliesToContent: projection.scopeContent,
      isEnabled: projection.isEnabled,
      isRegex: projection.isRegex,
      order: order
    )
  }
}
