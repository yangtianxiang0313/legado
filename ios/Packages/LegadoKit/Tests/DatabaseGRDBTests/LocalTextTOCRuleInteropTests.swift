import DatabaseGRDB
import Foundation
import LibraryDomain
import XCTest

final class LocalTextTOCRuleInteropTests: XCTestCase {
  func testRepositoryRestoresByAndroidIDAndReturnsSerialOrder() async throws {
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

    try await repository.restoreAndroidLocalTextTOCRules([
      .init(id: 2, name: "later", rule: "b", serialNumber: 9),
      .init(id: 1, name: "first", rule: "a", serialNumber: 1),
    ])

    let restored = try await repository.localTextTOCRules()
    XCTAssertEqual(restored.map(\.id), [1, 2])
    XCTAssertEqual(restored.map(\.name), ["first", "later"])
  }
}
