import AppUseCases
import DatabaseGRDB
import Foundation
import LibraryDomain
import Testing

@Suite("WebDAVLocalBookRecoveryTests")
struct WebDAVLocalBookRecoveryPersistenceTests {
  @Test func atomicallyRepointsManagedFileAndRebuildsChapters() async throws {
    let repository = try GRDBBookShelfRepository(path: ":memory:")
    let sourceID = AndroidWebDAVBookOrigin.encode(
      remoteURL: try #require(URL(string: "https://dav.example/books/book.txt")),
      serverID: 42
    )
    let imported = try await repository.importLocalText(
      candidate: ShelfBookCandidate(
        name: "远程本地书",
        author: "作者",
        kind: "TXT",
        lastChapter: "旧章",
        intro: "",
        bookURL: "file:///missing/book.txt",
        coverURL: nil,
        originName: "book.txt",
        sourceID: sourceID
      ),
      chapters: [LocalTextChapter(title: "旧章", content: "旧正文")]
    )

    let updated = try await repository.rebuildLocalText(
      bookID: imported.id,
      chapters: [
        LocalTextChapter(title: "第一章", content: "恢复正文"),
        LocalTextChapter(title: "第二章", content: "后续正文"),
      ],
      splitsLongChapters: true,
      managedReference: "file:///managed/recovered-book.txt"
    )

    #expect(updated.candidate.bookURL == "file:///managed/recovered-book.txt")
    #expect(updated.candidate.bookRequestExpression == "file:///managed/recovered-book.txt")
    #expect(updated.candidate.sourceID == sourceID)
    #expect(updated.chapterCount == 2)
    #expect(try await repository.chapters(bookID: imported.id).count == 2)
  }
}
