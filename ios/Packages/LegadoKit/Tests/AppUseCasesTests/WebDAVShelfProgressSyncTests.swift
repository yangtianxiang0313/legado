import AppUseCases
import IntegrationKit
import LibraryDomain
import Testing

@Suite("WebDAV shelf progress sync")
struct WebDAVShelfProgressSyncTests {
  @Test("applies only cloud progress ahead of local shelf state")
  func appliesAheadOnly() async throws {
    let books = [
      book(id: "ahead", chapter: 1, position: 20),
      book(id: "behind", chapter: 3, position: 10),
      book(id: "equal", chapter: 2, position: 5),
    ]
    let repository = ShelfProgressRepositoryStub(books: books)
    let loader = ShelfProgressLoaderStub(results: [
      identity("ahead"): .loaded(document("ahead", chapter: 2, position: 1)),
      identity("behind"): .loaded(document("behind", chapter: 2, position: 90)),
      identity("equal"): .loaded(document("equal", chapter: 2, position: 5)),
    ])

    let report = try await WebDAVShelfProgressSyncUseCase(
      repository: repository,
      loader: loader
    ).synchronize(configuration: try configuration())

    #expect(report.scannedCount == 3)
    #expect(report.appliedCount == 1)
    #expect(report.rollbackIgnoredCount == 1)
    #expect(report.unchangedCount == 1)
    #expect(report.failures.isEmpty)
    let saved = await repository.saved
    #expect(saved.keys.map(\.rawValue) == ["ahead"])
    #expect(saved[BookID(rawValue: "ahead")]?.position.chapterIndex == 2)
  }

  @Test("missing and remote failures remain distinct and do not stop scan")
  func isolatesRemoteFailures() async throws {
    let books = [
      book(id: "missing", chapter: 0, position: 0),
      book(id: "failed", chapter: 0, position: 0),
      book(id: "next", chapter: 0, position: 0),
    ]
    let repository = ShelfProgressRepositoryStub(books: books)
    let loader = ShelfProgressLoaderStub(results: [
      identity("missing"): .failed(.notFound),
      identity("failed"): .failed(.authenticationRejected),
      identity("next"): .loaded(document("next", chapter: 1, position: 0)),
    ])

    let report = try await WebDAVShelfProgressSyncUseCase(
      repository: repository,
      loader: loader
    ).synchronize(configuration: try configuration())

    #expect(report.missingCount == 1)
    #expect(report.appliedCount == 1)
    #expect(report.failures.count == 1)
    #expect(report.failures.first?.kind == .remote(.authenticationRejected))
  }

  @Test("one persistence failure does not block later books")
  func isolatesPersistenceFailure() async throws {
    let books = [
      book(id: "broken", chapter: 0, position: 0),
      book(id: "healthy", chapter: 0, position: 0),
    ]
    let repository = ShelfProgressRepositoryStub(
      books: books,
      failingIDs: [BookID(rawValue: "broken")]
    )
    let loader = ShelfProgressLoaderStub(results: [
      identity("broken"): .loaded(document("broken", chapter: 1, position: 0)),
      identity("healthy"): .loaded(document("healthy", chapter: 1, position: 0)),
    ])

    let report = try await WebDAVShelfProgressSyncUseCase(
      repository: repository,
      loader: loader
    ).synchronize(configuration: try configuration())

    #expect(report.appliedCount == 1)
    #expect(report.failures.count == 1)
    #expect(report.failures.first?.kind == .persistenceUnavailable)
    #expect(await repository.saved[BookID(rawValue: "healthy")] != nil)
  }

  private func book(
    id: String,
    chapter: Int,
    position: Int
  ) -> ShelfBookItem {
    ShelfBookItem(
      id: BookID(rawValue: id),
      candidate: ShelfBookCandidate(
        name: id,
        author: "author",
        kind: "web",
        lastChapter: "",
        intro: "",
        bookURL: "book://\(id)",
        coverURL: nil,
        originName: "source"
      ),
      membership: .member(groupID: 0),
      order: 0,
      chapterCount: 5,
      progress: ReadingProgress(
        position: ReadingPosition(
          chapterIndex: chapter,
          characterOffset: position
        ),
        chapterTitle: nil,
        updatedAtMilliseconds: 100
      )
    )
  }

  private func identity(_ id: String) -> WebDAVBookIdentity {
    WebDAVBookIdentity(name: id, author: "author")
  }

  private func document(
    _ id: String,
    chapter: Int,
    position: Int
  ) -> WebDAVBookProgressDocument {
    WebDAVBookProgressDocument(
      name: id,
      author: "author",
      durChapterIndex: chapter,
      durChapterPos: position,
      durChapterTime: 200,
      durChapterTitle: "chapter"
    )
  }

  private func configuration() throws -> WebDAVConnectionConfiguration {
    WebDAVConnectionConfiguration(
      serverURL: try #require(
        WebDAVServerURL(rawValue: "https://dav.example.test/dav")
      ),
      directoryName: "legado",
      credentialReference: WebDAVCredentialReference("credential")
    )
  }
}

private actor ShelfProgressRepositoryStub: WebDAVShelfProgressRepository {
  let books: [ShelfBookItem]
  let failingIDs: Set<BookID>
  var saved: [BookID: ReadingProgress] = [:]

  init(books: [ShelfBookItem], failingIDs: Set<BookID> = []) {
    self.books = books
    self.failingIDs = failingIDs
  }

  func shelfBooks() -> [ShelfBookItem] { books }

  func saveReadingProgress(
    bookID: BookID,
    progress: ReadingProgress
  ) throws {
    if failingIDs.contains(bookID) { throw PersistenceFailure.failed }
    saved[bookID] = progress
  }

  private enum PersistenceFailure: Error { case failed }
}

private struct ShelfProgressLoaderStub: WebDAVBookProgressLoading {
  let results: [WebDAVBookIdentity: WebDAVBookProgressLoadResult]

  func load(
    configuration: WebDAVConnectionConfiguration,
    identity: WebDAVBookIdentity
  ) async -> WebDAVBookProgressLoadResult {
    results[identity] ?? .failed(.notFound)
  }
}
