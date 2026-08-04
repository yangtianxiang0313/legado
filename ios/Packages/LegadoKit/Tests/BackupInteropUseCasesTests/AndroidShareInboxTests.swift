import BackupInteropUseCases
import Foundation
import Testing

@Suite("Android share inbox")
struct AndroidShareInboxTests {
  @Test func storesAndConsumesPayloadExactlyOnce() throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = AndroidShareInbox(containerURL: root)
    let expected = AndroidSharePayload(
      kind: .file,
      data: Data(#"[{"bookSourceUrl":"https://example.test"}]"#.utf8),
      suggestedName: "bookSource.json"
    )

    let token = try inbox.store(expected)
    #expect(try inbox.consume(token: token) == expected)
    #expect(throws: AndroidShareInboxError.missingPayload) {
      try inbox.consume(token: token)
    }
  }

  @Test func createsMinimalOpenURLAndParsesItsToken() throws {
    let token = UUID().uuidString.lowercased()
    let url = try AndroidShareInbox.openURL(token: token)
    #expect(url.absoluteString.hasPrefix("legado://import/inbox?token="))
    #expect(AndroidShareInbox.token(from: url) == token)
  }

  @Test func listsOnlyReadyPayloadTokens() throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = AndroidShareInbox(containerURL: root)
    let first = try inbox.store(AndroidSharePayload(
      kind: .text,
      data: Data("first".utf8)
    ))
    let second = try inbox.store(AndroidSharePayload(
      kind: .text,
      data: Data("second".utf8)
    ))

    #expect(Set(try inbox.pendingTokens()) == Set([first, second]))
  }

  @Test(arguments: [
    "../payload",
    "not-a-uuid",
    "00000000-0000-0000-0000-000000000000/metadata.json",
  ])
  func rejectsNonCanonicalToken(_ token: String) throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = AndroidShareInbox(containerURL: root)
    #expect(throws: AndroidShareInboxError.invalidToken) {
      try inbox.consume(token: token)
    }
  }

  @Test func rejectsOversizedPayloadBeforeWriting() throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = AndroidShareInbox(containerURL: root, maximumPayloadBytes: 4)
    #expect(throws: AndroidShareInboxError.payloadTooLarge) {
      try inbox.store(AndroidSharePayload(kind: .text, data: Data("12345".utf8)))
    }
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "AndroidShareInboxTests-\(UUID().uuidString)",
      isDirectory: true
    )
  }
}
