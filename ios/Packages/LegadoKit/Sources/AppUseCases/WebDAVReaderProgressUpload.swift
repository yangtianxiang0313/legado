import Foundation
import IntegrationKit
import LibraryDomain

public actor WebDAVReaderProgressUploadCoordinator {
  private struct Pending: Equatable, Sendable {
    let configuration: WebDAVConnectionConfiguration
    let document: WebDAVBookProgressDocument
  }

  private let saver: any WebDAVBookProgressSaving
  private let debounceNanoseconds: UInt64
  private var pending: Pending?
  private var worker: Task<Void, Never>?
  private var lastSubmitted: Pending?

  public private(set) var lastResult: WebDAVBookProgressSaveResult?

  public init(
    saver: any WebDAVBookProgressSaving,
    debounceNanoseconds: UInt64 = 500_000_000
  ) {
    self.saver = saver
    self.debounceNanoseconds = debounceNanoseconds
  }

  public func schedule(
    configuration: WebDAVConnectionConfiguration,
    book: ShelfBookItem,
    progress: ReadingProgress
  ) {
    let next = Pending(
      configuration: configuration,
      document: WebDAVBookProgressDocument(
        name: book.candidate.name,
        author: book.candidate.author,
        durChapterIndex: progress.position.chapterIndex,
        durChapterPos: progress.position.characterOffset,
        durChapterTime: progress.updatedAtMilliseconds,
        durChapterTitle: progress.chapterTitle
      )
    )
    guard next != pending, next != lastSubmitted else { return }
    pending = next
    worker?.cancel()
    worker = Task { [weak self] in
      guard let self else { return }
      do {
        try await Task.sleep(nanoseconds: debounceNanoseconds)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      _ = await uploadPending()
    }
  }

  @discardableResult
  public func flush() async -> WebDAVBookProgressSaveResult? {
    worker?.cancel()
    worker = nil
    return await uploadPending()
  }

  private func uploadPending() async -> WebDAVBookProgressSaveResult? {
    guard let pending else { return nil }
    self.pending = nil
    let result = await saver.save(
      configuration: pending.configuration,
      document: pending.document
    )
    if result == .saved {
      lastSubmitted = pending
    }
    lastResult = result
    return result
  }
}
