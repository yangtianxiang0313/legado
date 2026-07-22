import Foundation
import LegadoCore
import XCTest

@testable import SourceFormat

final class BookSourceRoundTripTests: XCTestCase {
  func testUnknownJSONKindsAndNumberTokensRoundTripAtEveryObjectBoundary() throws {
    let input = Data(
      #"""
      {
        "bookSourceUrl": "https://source.test",
        "unknownObject": {"nested": 1e500},
        "unknownArray": [1, "two", false, null],
        "unknownInteger": 12345678901234567890123456789012345678901234567890,
        "unknownDecimal": 0.123456789012345678901234567890123456789,
        "unknownString": "value",
        "unknownBool": true,
        "unknownNull": null,
        "ruleSearch": {"name": "", "searchUnknown": {"deep": 1}},
        "ruleExplore": {"exploreUnknown": [1, 2]},
        "ruleBookInfo": {"bookInfoUnknown": 1e500},
        "ruleToc": {"tocUnknown": "value"},
        "ruleContent": {"contentUnknown": false},
        "ruleReview": {"reviewUnknown": null}
      }
      """#.utf8
    )

    let source = try BookSourceCodec.decode(input)
    XCTAssertEqual(source.unknownFields.count, 7)
    XCTAssertEqual(source.unknownFields["unknownString"], .string("value"))
    XCTAssertEqual(source.unknownFields["unknownBool"], .bool(true))
    XCTAssertEqual(source.unknownFields["unknownNull"], .some(.null))
    XCTAssertEqual(try rawNumber(source, "unknownInteger"), "12345678901234567890123456789012345678901234567890")
    XCTAssertEqual(try rawNumber(source, "unknownDecimal"), "0.123456789012345678901234567890123456789")

    let search = try value(source.ruleSearch)
    let explore = try value(source.ruleExplore)
    let bookInfo = try value(source.ruleBookInfo)
    let toc = try value(source.ruleToc)
    let content = try value(source.ruleContent)
    let review = try value(source.ruleReview)
    XCTAssertEqual(search.name, .value(""))
    XCTAssertNotNil(search.unknownFields["searchUnknown"])
    XCTAssertNotNil(explore.unknownFields["exploreUnknown"])
    XCTAssertEqual(try rawNumber(bookInfo, "bookInfoUnknown"), "1e500")
    XCTAssertEqual(toc.unknownFields["tocUnknown"], .string("value"))
    XCTAssertEqual(content.unknownFields["contentUnknown"], .bool(false))
    XCTAssertEqual(review.unknownFields["reviewUnknown"], .some(.null))

    let canonical = try BookSourceCodec.encode(source)
    let second = try BookSourceCodec.encode(BookSourceCodec.decode(canonical))
    XCTAssertEqual(canonical, second)
    let text = String(decoding: canonical, as: UTF8.self)
    XCTAssertTrue(text.contains("12345678901234567890123456789012345678901234567890"))
    XCTAssertTrue(text.contains("0.123456789012345678901234567890123456789"))
    XCTAssertTrue(text.contains("1e500"))
  }

  func testPresenceDistinguishesMissingNullEmptyAndValueWithoutDefaults() throws {
    let empty = try BookSourceCodec.decode(Data("{}".utf8))
    XCTAssertEqual(empty.bookSourceUrl, .missing)
    XCTAssertEqual(empty.enabled, .missing)
    XCTAssertEqual(empty.respondTime, .missing)
    XCTAssertEqual(empty.ruleSearch, .missing)
    XCTAssertEqual(try BookSourceCodec.encode(empty), Data("{}".utf8))

    let explicit = try BookSourceCodec.decode(
      Data(
        #"{"bookSourceGroup":null,"bookSourceName":"","bookSourceUrl":"value","ruleSearch":null}"#.utf8
      )
    )
    XCTAssertEqual(explicit.bookSourceGroup, .null)
    XCTAssertEqual(explicit.bookSourceName, .value(""))
    XCTAssertEqual(explicit.bookSourceUrl, .value("value"))
    XCTAssertEqual(explicit.ruleSearch, .null)

    let emptyRule = try BookSourceCodec.decode(Data(#"{"ruleSearch":{}}"#.utf8))
    let emptySearch = try value(emptyRule.ruleSearch)
    XCTAssertEqual(emptySearch.name, .missing)
    XCTAssertTrue(emptySearch.rawFields.isEmpty)

    let populatedRule = try BookSourceCodec.decode(
      Data(#"{"ruleSearch":{"name":"value"}}"#.utf8)
    )
    XCTAssertEqual(try value(populatedRule.ruleSearch).name, .value("value"))
  }

  func testKnownFieldsNeverCoerceAndMismatchesRemainLossless() throws {
    let input = Data(
      #"""
      {
        "bookSourceName": false,
        "bookSourceType": "1",
        "customOrder": true,
        "enabled": 1,
        "lastUpdateTime": 9223372036854775808,
        "weight": 2147483648,
        "ruleSearch": "{\"name\":\"x\"}",
        "ruleBookInfo": {"name": 1}
      }
      """#.utf8
    )
    let source = try BookSourceCodec.decode(input)

    XCTAssertEqual(source.bookSourceName, .typeMismatch(.bool(false)))
    XCTAssertEqual(source.bookSourceType, .typeMismatch(.string("1")))
    XCTAssertEqual(source.customOrder, .typeMismatch(.bool(true)))
    XCTAssertEqual(
      source.enabled,
      .typeMismatch(.number(try JSONNumber(validating: "1")))
    )
    XCTAssertEqual(
      source.lastUpdateTime,
      .typeMismatch(.number(try JSONNumber(validating: "9223372036854775808")))
    )
    XCTAssertEqual(
      source.weight,
      .typeMismatch(.number(try JSONNumber(validating: "2147483648")))
    )
    XCTAssertEqual(source.ruleSearch, .typeMismatch(.string(#"{"name":"x"}"#)))
    XCTAssertEqual(try value(source.ruleBookInfo).name, .typeMismatch(.number(JSONNumber(1))))
    XCTAssertTrue(source.unknownFields.isEmpty)

    let canonicalInput = try JSONValueCodec.encode(JSONValueCodec.decode(input))
    XCTAssertEqual(try BookSourceCodec.encode(source), canonicalInput)
  }

  func testRootMustBeObjectAndDuplicateKeysFailClosed() {
    XCTAssertThrowsError(try BookSourceCodec.decode(Data("[]".utf8))) { error in
      XCTAssertEqual(error as? SourceFormatError, .expectedObject)
    }
    XCTAssertThrowsError(
      try BookSourceCodec.decode(Data(#"{"bookSourceUrl":"a","bookSourceUrl":"b"}"#.utf8))
    )
  }

  private func rawNumber(
    _ document: some LosslessSourceDocument,
    _ jsonName: String
  ) throws -> String {
    guard case .number(let number) = document.rawValue(for: jsonName) else {
      throw RoundTripTestError.expectedNumber
    }
    return number.rawToken
  }

  private func value<Value: Equatable & Sendable>(_ field: SourceField<Value>) throws -> Value {
    guard case .value(let value) = field else {
      throw RoundTripTestError.expectedValue
    }
    return value
  }
}

private enum RoundTripTestError: Error {
  case expectedNumber
  case expectedValue
}
