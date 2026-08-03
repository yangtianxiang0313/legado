import AppUseCases
import DatabaseGRDB
import Foundation
import Testing

@Suite("WebDAVBookOriginInteropTests")
struct WebDAVBookOriginPersistenceTests {
  @Test func persistsAndroidCompatibleOriginWithoutChangingBookURL() async throws {
    let repository = try GRDBBookShelfRepository(path: ":memory:")
    let local = ShelfBookCandidate(
      name: "论语",
      author: "孔子弟子",
      kind: "本地",
      lastChapter: "",
      intro: "",
      bookURL: "file:///managed/论语.txt",
      coverURL: nil,
      originName: "论语.txt",
      sourceID: "local-file"
    )
    let added = try await repository.add(local, groupID: 0)
    let remoteURL = try #require(
      URL(string: "https://dav.example/books/%E8%AE%BA%E8%AF%AD.txt")
    )

    _ = try await repository.updateBookInfo(
      bookID: added.id,
      candidate: AndroidWebDAVBookOrigin.applying(
        to: added.candidate,
        remoteURL: remoteURL,
        serverID: 42
      )
    )

    let stored = try #require(await repository.book(id: added.id))
    #expect(stored.candidate.bookURL == local.bookURL)
    #expect(
      stored.candidate.sourceID
        == "webDav::https://dav.example/books/%E8%AE%BA%E8%AF%AD.txt,{\"serverID\":42}"
    )
  }
}
