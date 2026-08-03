import AndroidBackupInterop
import AppUseCases
import Foundation
import LibraryDomain

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
    httpTextToSpeechEngineCount: Int = 0
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
}

public struct AndroidCoreBackupRestoreUseCase: Sendable {
  private let repository: any AndroidCoreBackupRestoreRepository

  public init(repository: any AndroidCoreBackupRestoreRepository) {
    self.repository = repository
  }

  public func restore(from archiveURL: URL) async throws
    -> AndroidCoreBackupRestoreSummary
  {
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
      httpTextToSpeechEngineCount: httpTextToSpeechEngines.count
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
