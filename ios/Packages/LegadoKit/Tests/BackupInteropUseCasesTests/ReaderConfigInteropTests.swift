import AndroidBackupInterop
import BackupInteropUseCases
import Foundation
import ReaderCore
import XCTest

final class ReaderConfigInteropTests: XCTestCase {
  func testDocumentsRoundTripLosslesslyAndSharedStyleProjectsPortableFields() throws {
    let listData = Data(#"[{"name":"paper","textSize":18,"future":{"x":1}}]"#.utf8)
    let sharedData = Data(##"{"name":"shared","textSize":26,"lineSpacingExtra":15,"bgStr":"#ffeecc"}"##.utf8)
    let bundle = try AndroidReaderConfigBundle(
      stylesData: listData,
      sharedStyleData: sharedData
    )

    XCTAssertEqual(bundle.projection?.fontSize, 26)
    XCTAssertEqual(bundle.projection?.lineSpacing, 15)
    XCTAssertEqual(
      try AndroidReaderConfigCodec.decodeList(bundle.encodedStyles()),
      try AndroidReaderConfigCodec.decodeList(listData)
    )
    XCTAssertEqual(
      try bundle.encodedSharedStyle().map {
        try AndroidReaderConfigCodec.decodeShared($0)
      },
      try AndroidReaderConfigCodec.decodeShared(sharedData)
    )

    let exported = bundle.applying(
      ReaderPreferences(fontSize: 30, lineSpacing: 8)
    )
    XCTAssertEqual(exported.sharedStyle?.integer("textSize"), 30)
    XCTAssertEqual(exported.sharedStyle?.integer("lineSpacingExtra"), 8)
    XCTAssertEqual(
      exported.sharedStyle?.rawFields["bgStr"],
      .string("#ffeecc")
    )
  }
}
