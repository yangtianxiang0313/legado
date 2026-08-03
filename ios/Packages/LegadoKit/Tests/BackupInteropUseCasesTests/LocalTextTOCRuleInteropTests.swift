import AndroidBackupInterop
import BackupInteropUseCases
import Foundation
import XCTest

final class LocalTextTOCRuleInteropTests: XCTestCase {
  func testAndroidDocumentRoundTripsKnownAndUnknownFields() throws {
    let input = Data(
      #"[{"id":-7,"name":"custom","rule":"^# .+$","example":null,"serialNumber":3,"enable":false,"future":"kept"}]"#.utf8
    )
    let documents = try AndroidLocalTextTOCRuleCodec.decodeMany(input)
    let values = AndroidLocalTextTOCRuleInteropAdapter.restoreValues(documents)

    XCTAssertEqual(values.first?.id, -7)
    XCTAssertEqual(values.first?.serialNumber, 3)
    XCTAssertEqual(values.first?.isEnabled, false)
    XCTAssertEqual(documents.first?.rawFields["future"], .string("kept"))
    XCTAssertEqual(
      try AndroidLocalTextTOCRuleCodec.decodeMany(
        AndroidLocalTextTOCRuleCodec.encodeMany(documents)
      ).first?.rawFields,
      documents.first?.rawFields
    )
  }
}
