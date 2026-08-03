import AndroidBackupInterop
import AppUseCases
import BackupInteropUseCases
import DatabaseGRDB
import Foundation
import LegadoCore
import Testing

@Suite("RuleSubscriptionInteropTests")
struct RuleSubscriptionInteropTests {
  @MainActor
  @Test func managesAndRoundTripsAndroidRuleSubscriptions() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try GRDBBookShelfRepository(
      path: directory.appendingPathComponent("library.sqlite").path
    )
    let store = RuleSubscriptionStore(repository: repository)
    let value = RuleSubscription(
      id: 100,
      name: "主书源订阅",
      url: "https://example.test/sources.json",
      type: 0,
      customOrder: 2,
      autoUpdate: true,
      updatedAt: 2_000
    )

    #expect(await store.save(value))
    #expect(store.subscriptions == [value])
    #expect(
      !(await store.save(RuleSubscription(
        id: 101,
        name: "重复地址",
        url: value.url,
        type: 2,
        customOrder: 3,
        autoUpdate: false,
        updatedAt: 3_000
      )))
    )

    let document = AndroidRuleSubscriptionDTO(
      id: value.id,
      name: value.name,
      url: value.url,
      type: value.type,
      customOrder: value.customOrder,
      autoUpdate: value.autoUpdate,
      updatedAt: value.updatedAt,
      unknownFields: ["future": .string("kept")]
    )
    let archiveURL = directory.appendingPathComponent("backup.zip")
    try AndroidBackupArchive.write(
      AndroidBackupContents(ruleSubscriptions: [document]),
      to: archiveURL
    )
    let decoded = try AndroidBackupArchive.readRuleSubscriptions(
      from: archiveURL
    )

    #expect(decoded == [document])
    #expect(decoded[0].rawFields["future"] == .string("kept"))
    #expect(
      AndroidRuleSubscriptionInteropAdapter.restoreValues(decoded)
        == [value]
    )
  }
}
