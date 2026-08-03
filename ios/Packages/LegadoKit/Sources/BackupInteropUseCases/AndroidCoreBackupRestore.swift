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

  public init(
    bookCount: Int,
    groupCount: Int,
    bookmarkCount: Int,
    bookSourceCount: Int,
    replacementRuleCount: Int,
    readRecordCount: Int = 0,
    searchHistoryCount: Int = 0,
    ruleSubscriptionCount: Int = 0
  ) {
    self.bookCount = bookCount
    self.groupCount = groupCount
    self.bookmarkCount = bookmarkCount
    self.bookSourceCount = bookSourceCount
    self.replacementRuleCount = replacementRuleCount
    self.readRecordCount = readRecordCount
    self.searchHistoryCount = searchHistoryCount
    self.ruleSubscriptionCount = ruleSubscriptionCount
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
}

public extension AndroidCoreBackupRestoreRepository {
  func restoreAndroidSearchHistory(
    _ entries: [SearchHistoryEntry]
  ) async throws {}

  func restoreAndroidRuleSubscriptions(
    _ values: [RuleSubscription]
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
    return AndroidCoreBackupRestoreSummary(
      bookCount: library.bookCount,
      groupCount: library.groupCount,
      bookmarkCount: library.bookmarkCount,
      bookSourceCount: bookSources.count,
      replacementRuleCount: replacementRules.count,
      readRecordCount: readRecords.count,
      searchHistoryCount: searchHistory.count,
      ruleSubscriptionCount: ruleSubscriptions.count
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
