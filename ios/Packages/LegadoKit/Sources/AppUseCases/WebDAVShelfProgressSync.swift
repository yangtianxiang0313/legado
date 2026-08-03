import IntegrationKit
import LibraryDomain

public protocol WebDAVShelfProgressRepository: Sendable {
  func shelfBooks() async throws -> [ShelfBookItem]
  func saveReadingProgress(
    bookID: LibraryDomain.BookID,
    progress: ReadingProgress
  ) async throws
}

public enum WebDAVShelfProgressSyncFailureKind: Equatable, Sendable {
  case remote(WebDAVBookProgressLoadFailure)
  case persistenceUnavailable
}

public struct WebDAVShelfProgressSyncFailure: Equatable, Sendable {
  public let bookID: LibraryDomain.BookID
  public let identity: WebDAVBookIdentity
  public let kind: WebDAVShelfProgressSyncFailureKind

  public init(
    bookID: LibraryDomain.BookID,
    identity: WebDAVBookIdentity,
    kind: WebDAVShelfProgressSyncFailureKind
  ) {
    self.bookID = bookID
    self.identity = identity
    self.kind = kind
  }
}

public struct WebDAVShelfProgressSyncReport: Equatable, Sendable {
  public let scannedCount: Int
  public let appliedCount: Int
  public let unchangedCount: Int
  public let rollbackIgnoredCount: Int
  public let missingCount: Int
  public let failures: [WebDAVShelfProgressSyncFailure]

  public init(
    scannedCount: Int,
    appliedCount: Int,
    unchangedCount: Int,
    rollbackIgnoredCount: Int,
    missingCount: Int,
    failures: [WebDAVShelfProgressSyncFailure]
  ) {
    self.scannedCount = scannedCount
    self.appliedCount = appliedCount
    self.unchangedCount = unchangedCount
    self.rollbackIgnoredCount = rollbackIgnoredCount
    self.missingCount = missingCount
    self.failures = failures
  }
}

public struct WebDAVShelfProgressSyncUseCase: Sendable {
  private let repository: any WebDAVShelfProgressRepository
  private let loader: any WebDAVBookProgressLoading

  public init(
    repository: any WebDAVShelfProgressRepository,
    loader: any WebDAVBookProgressLoading
  ) {
    self.repository = repository
    self.loader = loader
  }

  public func synchronize(
    configuration: WebDAVConnectionConfiguration
  ) async throws -> WebDAVShelfProgressSyncReport {
    let books = try await repository.shelfBooks()
    var appliedCount = 0
    var unchangedCount = 0
    var rollbackIgnoredCount = 0
    var missingCount = 0
    var failures: [WebDAVShelfProgressSyncFailure] = []

    for book in books {
      let identity = WebDAVBookIdentity(
        name: book.candidate.name,
        author: book.candidate.author
      )
      let loaded = await loader.load(
        configuration: configuration,
        identity: identity
      )
      guard case .loaded(let document) = loaded else {
        if case .failed(.notFound) = loaded {
          missingCount += 1
        } else if case .failed(let failure) = loaded {
          failures.append(
            WebDAVShelfProgressSyncFailure(
              bookID: book.id,
              identity: identity,
              kind: .remote(failure)
            )
          )
        }
        continue
      }

      let local = book.progress?.position
        ?? ReadingPosition(chapterIndex: 0, characterOffset: 0)
      let cloud = ReadingPosition(
        chapterIndex: document.durChapterIndex,
        characterOffset: document.durChapterPos
      )
      if cloud == local {
        unchangedCount += 1
        continue
      }
      guard Self.isAhead(cloud, of: local) else {
        rollbackIgnoredCount += 1
        continue
      }
      do {
        try await repository.saveReadingProgress(
          bookID: book.id,
          progress: ReadingProgress(
            position: cloud,
            chapterTitle: document.durChapterTitle,
            updatedAtMilliseconds: document.durChapterTime
          )
        )
        appliedCount += 1
      } catch {
        failures.append(
          WebDAVShelfProgressSyncFailure(
            bookID: book.id,
            identity: identity,
            kind: .persistenceUnavailable
          )
        )
      }
    }

    return WebDAVShelfProgressSyncReport(
      scannedCount: books.count,
      appliedCount: appliedCount,
      unchangedCount: unchangedCount,
      rollbackIgnoredCount: rollbackIgnoredCount,
      missingCount: missingCount,
      failures: failures
    )
  }

  private static func isAhead(
    _ lhs: ReadingPosition,
    of rhs: ReadingPosition
  ) -> Bool {
    lhs.chapterIndex > rhs.chapterIndex
      || (
        lhs.chapterIndex == rhs.chapterIndex
          && lhs.characterOffset > rhs.characterOffset
      )
  }
}

public enum WebDAVShelfProgressSyncOutcome: Equatable, Sendable {
  case synchronized(WebDAVShelfProgressSyncReport)
  case invalidConfiguration
  case repositoryUnavailable
}

public extension ShelfLibrary {
  func synchronizeWebDAVShelfProgress(
    configuration: WebDAVConnectionConfiguration?,
    loader: any WebDAVBookProgressLoading
  ) async -> WebDAVShelfProgressSyncOutcome {
    guard let configuration else { return .invalidConfiguration }
    do {
      let report = try await WebDAVShelfProgressSyncUseCase(
        repository: repository,
        loader: loader
      ).synchronize(configuration: configuration)
      if report.appliedCount > 0 {
        await reload()
      }
      return .synchronized(report)
    } catch {
      return .repositoryUnavailable
    }
  }
}
