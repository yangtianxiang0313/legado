import ReaderCore
import XCTest

final class ReaderContentImageProjectionTests: XCTestCase {
  func testProjectsInlineImagesWithoutLosingSourceAnchor() {
    let source = "前文<img src=\"https://img.test/a.jpg\">后文"
    let projection = ReaderContentImageProjection(sourceContent: source)

    XCTAssertEqual(
      projection.blocks,
      [.text("前文"), .image(sourceURL: "https://img.test/a.jpg"), .text("后文")]
    )
    XCTAssertEqual(projection.layoutText, "前文\u{FFFC}后文")

    let imageStart = (source as NSString).range(of: "<img").location
    XCTAssertEqual(
      projection.layoutOffset(forSourceOffset: imageStart + 8),
      2
    )
    XCTAssertEqual(projection.sourceOffset(forLayoutOffset: 2), imageStart)
    XCTAssertEqual(
      projection.sourceOffset(forLayoutOffset: (projection.layoutText as NSString).length),
      (source as NSString).length
    )
  }

  func testLeavesPlainTextAsOneUnchangedBlock() {
    let projection = ReaderContentImageProjection(sourceContent: "纯文本")
    XCTAssertEqual(projection.blocks, [.text("纯文本")])
    XCTAssertEqual(projection.layoutText, "纯文本")
    XCTAssertEqual(projection.layoutOffset(forSourceOffset: 1), 1)
    XCTAssertEqual(projection.sourceOffset(forLayoutOffset: 1), 1)
  }
}
