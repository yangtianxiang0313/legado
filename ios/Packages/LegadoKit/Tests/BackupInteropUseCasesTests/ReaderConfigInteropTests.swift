import AndroidBackupInterop
import BackupInteropUseCases
import Foundation
import LegadoCore
import ReaderCore
import XCTest

final class ReaderConfigInteropTests: XCTestCase {
  func testDocumentsRoundTripLosslesslyAndSharedStyleProjectsPortableFields() throws {
    let listData = Data(#"[{"name":"paper","textSize":18,"future":{"x":1}}]"#.utf8)
    let sharedData = Data(##"{"name":"shared","textSize":26,"lineSpacingExtra":15,"pageAnim":1,"textBold":1,"letterSpacing":0.25,"paragraphSpacing":7,"paragraphIndent":"　","titleMode":1,"paddingTop":18,"paddingBottom":9,"paddingLeft":24,"paddingRight":25,"bgStr":"#ffeecc"}"##.utf8)
    let bundle = try AndroidReaderConfigBundle(
      stylesData: listData,
      sharedStyleData: sharedData
    )

    XCTAssertEqual(bundle.projection?.fontSize, 26)
    XCTAssertEqual(bundle.projection?.lineSpacing, 15)
    XCTAssertEqual(bundle.projection?.pageAnimation, 1)
    XCTAssertEqual(bundle.projection?.layout.textWeight, 1)
    XCTAssertEqual(bundle.projection?.layout.letterSpacing, 0.25)
    XCTAssertEqual(bundle.projection?.layout.paragraphSpacing, 7)
    XCTAssertEqual(bundle.projection?.layout.paragraphIndent, "　")
    XCTAssertEqual(bundle.projection?.layout.titleMode, 1)
    XCTAssertEqual(bundle.projection?.layout.paddingTop, 18)
    XCTAssertEqual(bundle.projection?.layout.paddingBottom, 9)
    XCTAssertEqual(bundle.projection?.layout.paddingLeft, 24)
    XCTAssertEqual(bundle.projection?.layout.paddingRight, 25)
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
      ReaderPreferences(
        fontSize: 30,
        lineSpacing: 8,
        pageAnimation: 3,
        layout: ReaderLayoutPreferences(
          textWeight: 2,
          letterSpacing: -0.2,
          paragraphSpacing: 10,
          paragraphIndent: "",
          titleMode: 2,
          paddingTop: 20,
          paddingBottom: 10,
          paddingLeft: 30,
          paddingRight: 31
        )
      )
    )
    XCTAssertEqual(exported.sharedStyle?.integer("textSize"), 30)
    XCTAssertEqual(exported.sharedStyle?.integer("lineSpacingExtra"), 8)
    XCTAssertEqual(exported.sharedStyle?.integer("pageAnim"), 3)
    XCTAssertEqual(exported.sharedStyle?.integer("textBold"), 2)
    XCTAssertEqual(
      exported.sharedStyle?.rawFields["letterSpacing"],
      .number(try JSONNumber(validating: "-0.2"))
    )
    XCTAssertEqual(exported.sharedStyle?.integer("paragraphSpacing"), 10)
    XCTAssertEqual(
      exported.sharedStyle?.rawFields["paragraphIndent"],
      .string("")
    )
    XCTAssertEqual(exported.sharedStyle?.integer("titleMode"), 2)
    XCTAssertEqual(exported.sharedStyle?.integer("paddingTop"), 20)
    XCTAssertEqual(exported.sharedStyle?.integer("paddingBottom"), 10)
    XCTAssertEqual(exported.sharedStyle?.integer("paddingLeft"), 30)
    XCTAssertEqual(exported.sharedStyle?.integer("paddingRight"), 31)
    XCTAssertEqual(
      exported.sharedStyle?.rawFields["bgStr"],
      .string("#ffeecc")
    )
  }
}
