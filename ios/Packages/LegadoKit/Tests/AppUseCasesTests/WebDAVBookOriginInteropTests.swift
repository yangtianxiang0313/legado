import AppUseCases
import Foundation
import Testing

@Suite("WebDAVBookOriginInteropTests")
struct WebDAVBookOriginInteropTests {
  @Test func encodesAndroidCustomURLAndPreservesLocalIdentity() throws {
    let candidate = ShelfBookCandidate(
      name: "论语",
      author: "孔子弟子",
      kind: "本地",
      lastChapter: "尧曰第二十",
      intro: "",
      bookURL: "file:///managed/论语.txt",
      tocURL: "file:///managed/论语.txt",
      coverURL: nil,
      originName: "论语.txt",
      sourceID: "local-file",
      variables: ["charset": "utf-8"]
    )
    let remoteURL = try #require(
      URL(string: "https://dav.example/books/%E8%AE%BA%E8%AF%AD.txt")
    )

    let updated = AndroidWebDAVBookOrigin.applying(
      to: candidate,
      remoteURL: remoteURL,
      serverID: 42
    )

    #expect(
      updated.sourceID
        == "webDav::https://dav.example/books/%E8%AE%BA%E8%AF%AD.txt,{\"serverID\":42}"
    )
    #expect(updated.bookURL == candidate.bookURL)
    #expect(updated.originName == candidate.originName)
    #expect(updated.variables == candidate.variables)
  }
}
