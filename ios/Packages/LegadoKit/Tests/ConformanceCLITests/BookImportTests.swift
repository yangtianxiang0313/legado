import Foundation
import XCTest

@testable import ConformanceCLI
@testable import TestSupport

extension LibraryDomainTests {
  func testRemoteExistingBookShortCircuitsWithoutNetwork() {
    let result = BookImportDomainProbe.existingRemoteBook()

    XCTAssertEqual(result.outcome, "existing")
    XCTAssertEqual(result.sourceSelection, "existing_short_circuit")
    XCTAssertEqual(result.networkRequestCount, 0)
    XCTAssertEqual(result.names, ["Existing Oracle Book"])
  }

  func testInvalidPatternDoesNotBlockNextMatchingSource() {
    let result = BookImportDomainProbe.patternAfterInvalid()

    XCTAssertEqual(result.outcome, "added")
    XCTAssertEqual(result.sourceSelection, "pattern")
    XCTAssertEqual(result.networkRequestCount, 1)
  }

  func testUnmatchedRemoteBookSkipsWithoutNetwork() {
    let result = BookImportDomainProbe.unmatchedRemoteBook()

    XCTAssertEqual(result.outcome, "skipped")
    XCTAssertEqual(result.sourceSelection, "none")
    XCTAssertEqual(result.networkRequestCount, 0)
    XCTAssertTrue(result.names.isEmpty)
  }

  func testChineseFileNameKeepsAndroidPrefixInAuthor() {
    let result = BookImportDomainProbe.chineseFileName()

    XCTAssertEqual(result.outcome, "added")
    XCTAssertEqual(result.names, ["星河"])
    XCTAssertEqual(result.authors, ["前缀甲"])
  }

  func testReimportPreservesIdentityButClearsOldChapters() {
    let result = BookImportDomainProbe.reimport()

    XCTAssertEqual(result.outcome, "updated")
    XCTAssertEqual(result.names, ["银河"])
    XCTAssertEqual(result.authors, ["Bob"])
    XCTAssertEqual(result.chapterCounts, [0])
  }

  func testEmptyFileIsRejectedBeforeBookCreation() {
    let result = BookImportDomainProbe.emptyFile()

    XCTAssertEqual(result.outcome, "rejected")
    XCTAssertEqual(result.exception, "EmptyFileException")
    XCTAssertTrue(result.names.isEmpty)
  }

  func testArchiveFiltersUnsupportedEntriesAndMarksOrigin() {
    let result = BookImportDomainProbe.archive()

    XCTAssertEqual(result.outcome, "archive_added")
    XCTAssertEqual(result.names, ["远方"])
    XCTAssertEqual(result.authors, ["压缩乙"])
    XCTAssertEqual(result.isArchive, [true])
  }

  func testRecursiveScanIncludesHiddenSupportedFilesInBatches() {
    let result = BookImportDomainProbe.recursiveScan()

    XCTAssertEqual(
      result.names,
      [
        ".hidden.txt",
        "bundle.zip",
        "inner.epub",
        "secret.pdf",
        "visible.txt",
      ]
    )
    XCTAssertEqual(result.batchCount, 3)
  }
}

extension ConformanceCLITests {
  func testMinimalTaskRunnerMatchesBookImportAndroidGolden()
    async throws
  {
    let temporaryRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let fixtureID = BookImportConformanceRunner.fixtureID
    let fixturePath =
      "ios/harness/fixtures/runtime-lab/\(fixtureID)"
    let goldenPath =
      "ios/harness/goldens/android-legado-v1/\(fixtureID).json"
    let taskPath = "ios/project/loop/task.json"
    for relative in [fixturePath, goldenPath, taskPath] {
      try FileManager.default.createDirectory(
        at:
          temporaryRoot
          .appendingPathComponent(relative)
          .deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
    }
    try FileManager.default.copyItem(
      at: bookImportRepositoryRoot.appendingPathComponent(fixturePath),
      to: temporaryRoot.appendingPathComponent(fixturePath)
    )
    try FileManager.default.copyItem(
      at: bookImportRepositoryRoot.appendingPathComponent(goldenPath),
      to: temporaryRoot.appendingPathComponent(goldenPath)
    )
    let task = try JSONSerialization.data(
      withJSONObject: [
        "schema_version": 2,
        "id": "IOS-LIBRARY-DOMAIN-BOOK-IMPORT-CHANNEL-RUNTIME-001",
        "source": [
          "fixture_id": fixtureID,
          "android_golden": goldenPath,
        ],
      ],
      options: [.sortedKeys]
    )
    try task.write(to: temporaryRoot.appendingPathComponent(taskPath))

    let run = try await MinimalTaskConformanceRunner.run(
      taskPath: taskPath,
      repositoryRoot: temporaryRoot
    )
    let text = String(decoding: run.data, as: UTF8.self)

    XCTAssertTrue(run.passed)
    XCTAssertTrue(text.contains(#""first_divergence":null"#))
    XCTAssertTrue(text.contains(#""author":"前缀甲""#))
    XCTAssertTrue(text.contains(#""add_batch_count":3"#))
  }

  private var bookImportRepositoryRoot: URL {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<6 {
      root.deleteLastPathComponent()
    }
    return root
  }
}
