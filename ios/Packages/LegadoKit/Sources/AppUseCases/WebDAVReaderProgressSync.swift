import Foundation
import IntegrationKit
import LibraryDomain
import ReaderCore

public enum WebDAVReaderProgressSyncFailure: Sendable, Equatable {
  case invalidConfiguration
  case remote(WebDAVBookProgressLoadFailure)
  case missingBook
  case persistenceUnavailable
}

public enum WebDAVReaderProgressSyncOutcome: Sendable, Equatable {
  case applied(ReadingProgress)
  case confirmationRequired(ReadingProgress)
  case failed(WebDAVReaderProgressSyncFailure)
}

public struct WebDAVReaderProgressSyncUseCase: Sendable {
  private let loader: any WebDAVBookProgressLoading

  public init(loader: any WebDAVBookProgressLoading) {
    self.loader = loader
  }

  public func resolve(
    configuration: WebDAVConnectionConfiguration,
    book: ShelfBookItem
  ) async -> WebDAVReaderProgressSyncOutcome {
    let identity = WebDAVBookIdentity(
      name: book.candidate.name,
      author: book.candidate.author
    )
    let loaded = await loader.load(
      configuration: configuration,
      identity: identity
    )
    guard case .loaded(let document) = loaded else {
      if case .failed(let failure) = loaded {
        return .failed(.remote(failure))
      }
      return .failed(.remote(.transportUnavailable))
    }
    let local = book.progress?.position
      ?? ReadingPosition(chapterIndex: 0, characterOffset: 0)
    let cloud = ReadingPosition(
      chapterIndex: document.durChapterIndex,
      characterOffset: document.durChapterPos
    )
    let progress = ReadingProgress(
      position: cloud,
      chapterTitle: document.durChapterTitle,
      updatedAtMilliseconds: document.durChapterTime
    )
    switch AndroidReaderProgressSyncPolicy.decision(
      local: local,
      cloud: cloud
    ) {
    case .applyCloud:
      return .applied(progress)
    case .requireRollbackConfirmation:
      return .confirmationRequired(progress)
    }
  }
}

public extension WebDAVConnectionSettings {
  var connectionConfiguration: WebDAVConnectionConfiguration? {
    guard let serverURL = WebDAVServerURL(rawValue: serverAddress) else {
      return nil
    }
    return WebDAVConnectionConfiguration(
      serverURL: serverURL,
      directoryName: directoryName,
      credentialReference: credentialReference
    )
  }
}

public extension ShelfLibrary {
  func synchronizeWebDAVReaderProgress(
    bookID: LibraryDomain.BookID,
    configuration: WebDAVConnectionConfiguration?,
    loader: any WebDAVBookProgressLoading
  ) async -> WebDAVReaderProgressSyncOutcome {
    guard let configuration else {
      return .failed(.invalidConfiguration)
    }
    guard let book = try? await repository.book(id: bookID) else {
      return .failed(.missingBook)
    }
    let outcome = await WebDAVReaderProgressSyncUseCase(
      loader: loader
    ).resolve(configuration: configuration, book: book)
    guard case .applied(let progress) = outcome else {
      return outcome
    }
    return await persistWebDAVReaderProgress(
      progress,
      bookID: bookID,
      success: outcome
    )
  }

  func confirmWebDAVReaderProgress(
    _ progress: ReadingProgress,
    bookID: LibraryDomain.BookID
  ) async -> WebDAVReaderProgressSyncOutcome {
    await persistWebDAVReaderProgress(
      progress,
      bookID: bookID,
      success: .applied(progress)
    )
  }

  private func persistWebDAVReaderProgress(
    _ progress: ReadingProgress,
    bookID: LibraryDomain.BookID,
    success: WebDAVReaderProgressSyncOutcome
  ) async -> WebDAVReaderProgressSyncOutcome {
    do {
      try await repository.saveReadingProgress(
        bookID: bookID,
        progress: progress
      )
      await reload()
      return success
    } catch {
      return .failed(.persistenceUnavailable)
    }
  }
}
