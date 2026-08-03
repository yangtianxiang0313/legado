import Foundation

public struct AndroidLibraryRestoreSummary: Equatable, Sendable {
  public let bookCount: Int
  public let groupCount: Int
  public let bookmarkCount: Int

  public init(
    bookCount: Int,
    groupCount: Int,
    bookmarkCount: Int
  ) {
    self.bookCount = bookCount
    self.groupCount = groupCount
    self.bookmarkCount = bookmarkCount
  }
}

public protocol AndroidLibraryRestoreRepository: Sendable {
  func restoreAndroidLibrary(
    _ plan: AndroidLibraryRestorePlan
  ) async throws -> AndroidLibraryRestoreSummary
}

public struct AndroidLibraryRestoreUseCase: Sendable {
  private let repository: any AndroidLibraryRestoreRepository

  public init(repository: any AndroidLibraryRestoreRepository) {
    self.repository = repository
  }

  public func restore(
    from archiveURL: URL
  ) async throws -> AndroidLibraryRestoreSummary {
    let plan = try AndroidLibraryImportAdapter.plan(from: archiveURL)
    return try await repository.restoreAndroidLibrary(plan)
  }
}
