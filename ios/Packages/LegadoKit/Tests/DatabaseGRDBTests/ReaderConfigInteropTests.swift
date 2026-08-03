import BackupInteropUseCases
import DatabaseGRDB
import Foundation
import XCTest

final class ReaderConfigInteropTests: XCTestCase {
  func testDatabasePersistsLosslessReaderConfigBundle() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try GRDBBookShelfRepository(
      path: directory.appendingPathComponent("library.sqlite").path
    )
    let bundle = try AndroidReaderConfigBundle(
      stylesData: Data(#"[{"textSize":19,"unknown":true}]"#.utf8),
      sharedStyleData: Data(#"{"textSize":24,"lineSpacingExtra":9}"#.utf8)
    )

    try await repository.restoreAndroidReaderConfigBundle(bundle)
    let loaded = try await repository.androidReaderConfigBundle()
    let restored = try XCTUnwrap(loaded)

    XCTAssertEqual(restored, bundle)
    XCTAssertEqual(restored.projection?.fontSize, 24)
  }
}
