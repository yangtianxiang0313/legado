import AppUseCases
import XCTest

final class LocalArchiveImportTests: XCTestCase {
  func testSelectsReadableBooksInArchiveOrderAndReportsDeferredFormats() throws {
    let plan = try LocalArchiveImportPlanner.plan(
      members: [
        .init(path: "说明.md", byteCount: 10),
        .init(path: "古典/《论语》作者：孔子.TXT", byteCount: 20),
        .init(path: "小说/星河.epub", byteCount: 30),
        .init(path: "旧书.umd", byteCount: 40),
        .init(path: "扫描.pdf", byteCount: 50),
      ]
    )

    XCTAssertEqual(
      plan.entries,
      [
        .init(
          path: "古典/《论语》作者：孔子.TXT",
          fileName: "《论语》作者：孔子.TXT",
          format: .text
        ),
        .init(
          path: "小说/星河.epub",
          fileName: "星河.epub",
          format: .epub
        ),
      ]
    )
    XCTAssertEqual(
      plan.skipped,
      [
        .init(path: "说明.md", reason: .unrelatedFile),
        .init(path: "旧书.umd", reason: .unsupportedBookFormat),
        .init(path: "扫描.pdf", reason: .unsupportedBookFormat),
      ]
    )
  }

  func testRejectsArchiveWithoutCurrentlyReadableEntry() {
    XCTAssertThrowsError(
      try LocalArchiveImportPlanner.plan(
        members: [
          .init(path: "cover.jpg", byteCount: 10),
          .init(path: "legacy.umd", byteCount: 20),
        ]
      )
    ) { error in
      XCTAssertEqual(
        error as? LocalArchiveImportFailure,
        .noSupportedBookEntry
      )
    }
  }

  func testEncodesAndroidArchiveOriginExactly() {
    let value = AndroidLocalArchiveBookOrigin.encode(
      archiveName: "我的书库.zip"
    )
    XCTAssertEqual(value, "loc_book::我的书库.zip")
    XCTAssertEqual(
      AndroidLocalArchiveBookOrigin.decode(value),
      "我的书库.zip"
    )
    XCTAssertNil(AndroidLocalArchiveBookOrigin.decode("local-file"))
  }
}
