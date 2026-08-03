import AppUseCases
import DatabaseGRDB
import Foundation
import Testing

@Suite("WebDAVRemoteBookRefreshTests")
struct WebDAVRemoteBookRefreshPersistenceTests {
  @Test func persistsCheckTimeAndCanDowngradeMissingRemoteToLocal() async throws {
    let repository = try GRDBBookShelfRepository(path: ":memory:")
    let remoteSource = AndroidWebDAVBookOrigin.encode(
      remoteURL: try #require(URL(string: "https://dav.example/books/book.txt")),
      serverID: 42
    )
    let book = try await repository.add(
      ShelfBookCandidate(
        name: "书",
        author: "作者",
        kind: "TXT",
        lastChapter: "",
        intro: "",
        bookURL: "file:///managed/book.txt",
        coverURL: nil,
        originName: "book.txt",
        sourceID: remoteSource
      ),
      groupID: 0
    )

    let checked = try await repository.updateWebDAVBookState(
      bookID: book.id,
      sourceID: remoteSource,
      lastCheckTime: 2_000
    )
    #expect(checked.lastCheckTime == 2_000)
    #expect(checked.candidate.sourceID == remoteSource)

    let downgraded = try await repository.updateWebDAVBookState(
      bookID: book.id,
      sourceID: "local-file",
      lastCheckTime: 0
    )
    #expect(downgraded.lastCheckTime == 0)
    #expect(downgraded.candidate.sourceID == "local-file")
  }
}
