import AndroidBackupInterop
import AppUseCases
import Foundation

public struct AndroidCoreBackupRestoreSummary: Equatable, Sendable {
  public let bookCount: Int
  public let groupCount: Int
  public let bookmarkCount: Int
  public let bookSourceCount: Int
  public let replacementRuleCount: Int

  public init(
    bookCount: Int,
    groupCount: Int,
    bookmarkCount: Int,
    bookSourceCount: Int,
    replacementRuleCount: Int
  ) {
    self.bookCount = bookCount
    self.groupCount = groupCount
    self.bookmarkCount = bookmarkCount
    self.bookSourceCount = bookSourceCount
    self.replacementRuleCount = replacementRuleCount
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

    let library = try await repository.restoreAndroidLibrary(libraryPlan)
    if !bookSources.isEmpty {
      try await repository.restoreAndroidBookSources(bookSources)
    }
    if !replacementRules.isEmpty {
      try await repository.restoreAndroidReplacementRules(replacementRules)
    }
    return AndroidCoreBackupRestoreSummary(
      bookCount: library.bookCount,
      groupCount: library.groupCount,
      bookmarkCount: library.bookmarkCount,
      bookSourceCount: bookSources.count,
      replacementRuleCount: replacementRules.count
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
